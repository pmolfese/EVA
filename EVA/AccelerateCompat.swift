//
//  AccelerateCompat.swift
//  EVA
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  Released under the terms of the GNU General Public License, version 3 (GPL-3.0).
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Thin compatibility shim for the modern Accelerate LAPACK headers, enabled by
//  the `-Xcc -DACCELERATE_NEW_LAPACK` build flag (REFACTOR.md L4.5). The new
//  headers replace the legacy `__CLPK_integer` scalar type with `__LAPACK_int`;
//  isolating that behind one typealias keeps the LAPACK call sites
//  (LinearAlgebra, BCGDetector) stable if the type shifts again.
//

import Accelerate

/// LAPACK integer scalar under the new Accelerate headers (Int32 on LP64).
typealias LAPACKInt = __LAPACK_int
