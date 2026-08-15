//
//  FigureExportTests.swift
//  EVATests
//
//  Developed by P. Molfese, National Institutes of Health (NIH).
//
//  This software is a "work of the United States Government" prepared by a federal
//  employee as part of official duties. As such, it is not subject to copyright
//  protection within the United States (17 U.S.C. § 105). International copyrights
//  may apply.
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

/// `FigureExportBasket.filenames`/`sanitizedPrefix` — the naming scheme for
/// "Export Individually", exercised without a real folder picker. See that
/// file's header for why the numbering has to match what the basket list
/// shows: the whole point of the feature is that the file on disk and the row
/// in the window agree on which figure is which.
@MainActor
struct FigureExportBasketNamingTests {

    @Test func namesAreOneIndexedAndPadded() {
        let names = FigureExportBasket.filenames(prefix: "Fig", count: 3, format: .pdf)
        #expect(names == ["Fig-1.pdf", "Fig-2.pdf", "Fig-3.pdf"])
    }

    @Test func doubleDigitCountsArePaddedForFinderSortOrder() {
        let names = FigureExportBasket.filenames(prefix: "Fig", count: 12, format: .png)
        #expect(names.first == "Fig-01.png")
        #expect(names[8] == "Fig-09.png")
        #expect(names[9] == "Fig-10.png")
        #expect(names.last == "Fig-12.png")
        // Lexical (Finder default) order must already be numeric order.
        #expect(names == names.sorted())
    }

    @Test func zeroItemsProducesNoNames() {
        #expect(FigureExportBasket.filenames(prefix: "Fig", count: 0, format: .pdf).isEmpty)
    }

    @Test func prefixSpacesBecomeHyphensAndPathSeparatorsAreStripped() {
        #expect(FigureExportBasket.sanitizedPrefix("Grand Average") == "Grand-Average")
        #expect(FigureExportBasket.sanitizedPrefix("Cond: A/B") == "Cond-AB")
    }

    @Test func blankOrAllInvalidPrefixFallsBackRatherThanProducingABareNumber() {
        #expect(FigureExportBasket.sanitizedPrefix("") == "EVA-Figure")
        #expect(FigureExportBasket.sanitizedPrefix("   ") == "EVA-Figure")
        #expect(FigureExportBasket.sanitizedPrefix("/:") == "EVA-Figure")
    }

}
