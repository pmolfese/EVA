#!/usr/bin/env python3
"""Convert the official ICLabel MatConvNet weights to Core ML.

Usage:
    python Tools/convert_iclabel_to_coreml.py \
        --mat /path/to/netICL.mat \
        --output EVA/Models/ICLabel.mlpackage

The source `.mat` file is the default ICLabel network from:
https://github.com/sccn/ICLabel
"""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np
import scipy.io as sio
import torch
from torch import nn


CLASS_LABELS = [
    "Brain",
    "Muscle",
    "Eye",
    "Heart",
    "Line Noise",
    "Channel Noise",
    "Other",
]


def _as_struct_array(value):
    return np.atleast_1d(value)


def _load_params(mat_path: Path) -> dict[str, np.ndarray | None]:
    data = sio.loadmat(mat_path, squeeze_me=True, struct_as_record=False)
    params = {}
    for param in _as_struct_array(data["params"]):
        value = getattr(param, "value", None)
        params[param.name] = None if value is None else np.asarray(value, dtype=np.float32)
    return params


def _reshape_weight(array: np.ndarray, shape: tuple[int, ...]) -> np.ndarray:
    if array.shape == shape:
        return array
    return np.reshape(array, shape)


def _conv2d_weight(params: dict[str, np.ndarray | None], name: str, shape: tuple[int, int, int, int]) -> torch.Tensor:
    value = params[name]
    if value is None:
        raise ValueError(f"missing weight {name}")
    value = _reshape_weight(value, shape)
    # MatConvNet stores weights as H x W x inputChannels x outputChannels.
    return torch.from_numpy(np.transpose(value, (3, 2, 0, 1)).copy())


def _bias(params: dict[str, np.ndarray | None], name: str, channels: int) -> torch.Tensor:
    value = params.get(name)
    if value is None:
        return torch.zeros(channels, dtype=torch.float32)
    return torch.from_numpy(np.asarray(value, dtype=np.float32).reshape(channels).copy())


class ICLabelNet(nn.Module):
    """PyTorch equivalent of ICLabel's default MatConvNet DAG."""

    def __init__(self, params: dict[str, np.ndarray | None]):
        super().__init__()
        self.image1 = nn.Conv2d(1, 128, kernel_size=4, stride=2, padding=1)
        self.image2 = nn.Conv2d(128, 256, kernel_size=4, stride=2, padding=1)
        self.image3 = nn.Conv2d(256, 512, kernel_size=4, stride=2, padding=1)

        self.psd1 = nn.Conv2d(1, 128, kernel_size=(1, 3), padding=(0, 1))
        self.psd2 = nn.Conv2d(128, 256, kernel_size=(1, 3), padding=(0, 1))
        self.psd3 = nn.Conv2d(256, 1, kernel_size=(1, 3), padding=(0, 1))

        self.autocorr1 = nn.Conv2d(1, 128, kernel_size=(1, 3), padding=(0, 1))
        self.autocorr2 = nn.Conv2d(128, 256, kernel_size=(1, 3), padding=(0, 1))
        self.autocorr3 = nn.Conv2d(256, 1, kernel_size=(1, 3), padding=(0, 1))

        self.classifier = nn.Conv2d(712, 7, kernel_size=4)
        self.activation = nn.LeakyReLU(negative_slope=0.2)

        self._load_matconvnet_params(params)

    def _copy_conv(
        self,
        layer: nn.Conv2d,
        params: dict[str, np.ndarray | None],
        weight_name: str,
        bias_name: str,
        weight_shape: tuple[int, int, int, int],
    ) -> None:
        layer.weight.data.copy_(_conv2d_weight(params, weight_name, weight_shape))
        layer.bias.data.copy_(_bias(params, bias_name, layer.out_channels))

    def _load_matconvnet_params(self, params: dict[str, np.ndarray | None]) -> None:
        self._copy_conv(
            self.image1,
            params,
            "discriminator_image_layer1_conv_kernel",
            "discriminator_image_layer1_conv_bias",
            (4, 4, 1, 128),
        )
        self._copy_conv(
            self.image2,
            params,
            "discriminator_image_layer2_conv_kernel",
            "discriminator_image_layer2_conv_bias",
            (4, 4, 128, 256),
        )
        self._copy_conv(
            self.image3,
            params,
            "discriminator_image_layer3_conv_kernel",
            "discriminator_image_layer3_conv_bias",
            (4, 4, 256, 512),
        )

        self._copy_conv(
            self.psd1,
            params,
            "discriminator_psdmed_layer1_conv_kernel",
            "discriminator_psdmed_layer1_conv_bias",
            (1, 3, 1, 128),
        )
        self._copy_conv(
            self.psd2,
            params,
            "discriminator_psdmed_layer2_conv_kernel",
            "discriminator_psdmed_layer2_conv_bias",
            (1, 3, 128, 256),
        )
        self._copy_conv(
            self.psd3,
            params,
            "discriminator_psdmed_layer3_conv_kernel",
            "discriminator_psdmed_layer3_conv_bias",
            (1, 3, 256, 1),
        )

        self._copy_conv(
            self.autocorr1,
            params,
            "discriminator_autocorr_layer1_conv_kernel",
            "discriminator_autocorr_layer1_conv_bias",
            (1, 3, 1, 128),
        )
        self._copy_conv(
            self.autocorr2,
            params,
            "discriminator_autocorr_layer2_conv_kernel",
            "discriminator_autocorr_layer2_conv_bias",
            (1, 3, 128, 256),
        )
        self._copy_conv(
            self.autocorr3,
            params,
            "discriminator_autocorr_layer3_conv_kernel",
            "discriminator_autocorr_layer3_conv_bias",
            (1, 3, 256, 1),
        )

        self._copy_conv(
            self.classifier,
            params,
            "discriminator_conv_kernel",
            "discriminator_conv_bias",
            (4, 4, 712, 7),
        )

    def _psd_branch(self, x: torch.Tensor) -> torch.Tensor:
        x = self.activation(self.psd1(x))
        x = self.activation(self.psd2(x))
        x = self.activation(self.psd3(x))
        x = x.reshape(x.shape[0], 100, 1, 1)
        return x.expand(-1, -1, 4, 4)

    def _autocorr_branch(self, x: torch.Tensor) -> torch.Tensor:
        x = self.activation(self.autocorr1(x))
        x = self.activation(self.autocorr2(x))
        x = self.activation(self.autocorr3(x))
        x = x.reshape(x.shape[0], 100, 1, 1)
        return x.expand(-1, -1, 4, 4)

    def forward(self, image: torch.Tensor, psd: torch.Tensor, autocorr: torch.Tensor) -> torch.Tensor:
        image_features = self.activation(self.image1(image))
        image_features = self.activation(self.image2(image_features))
        image_features = self.activation(self.image3(image_features))

        features = torch.cat(
            [image_features, self._psd_branch(psd), self._autocorr_branch(autocorr)],
            dim=1,
        )
        logits = self.classifier(features).reshape(features.shape[0], 7)
        return torch.softmax(logits, dim=1)


def convert(mat_path: Path, output_path: Path) -> None:
    params = _load_params(mat_path)
    model = ICLabelNet(params).eval()

    image = torch.zeros(1, 1, 32, 32, dtype=torch.float32)
    psd = torch.zeros(1, 1, 1, 100, dtype=torch.float32)
    autocorr = torch.zeros(1, 1, 1, 100, dtype=torch.float32)
    traced = torch.jit.trace(model, (image, psd, autocorr))

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS13,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="image", shape=image.shape, dtype=np.float32),
            ct.TensorType(name="psd", shape=psd.shape, dtype=np.float32),
            ct.TensorType(name="autocorr", shape=autocorr.shape, dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="probabilities", dtype=np.float32)],
    )
    mlmodel.short_description = "Official ICLabel default network converted from MatConvNet to Core ML."
    mlmodel.user_defined_metadata["source"] = "https://github.com/sccn/ICLabel/netICL.mat"
    mlmodel.user_defined_metadata["classes"] = ",".join(CLASS_LABELS)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(output_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mat", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    convert(args.mat, args.output)


if __name__ == "__main__":
    main()
