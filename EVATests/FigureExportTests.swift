//
//  FigureExportTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Figure-export format → UTType / extension mapping. Rendering itself is UI and
//  verified manually.
//

import Testing
import UniformTypeIdentifiers
@testable import EVA

struct FigureExportTests {

    @Test func formatExtensionsAndTypes() {
        #expect(FigureFormat.allCases.count == 3)

        #expect(FigureFormat.png.fileExtension == "png")
        #expect(FigureFormat.jpeg.fileExtension == "jpg")
        #expect(FigureFormat.pdf.fileExtension == "pdf")

        #expect(FigureFormat.png.contentType == .png)
        #expect(FigureFormat.jpeg.contentType == .jpeg)
        #expect(FigureFormat.pdf.contentType == .pdf)

        #expect(FigureFormat.png.label == "PNG")
        #expect(FigureFormat.jpeg.label == "JPEG")
        #expect(FigureFormat.pdf.label == "PDF")
    }
}
