import Foundation
import Testing
@testable import EVA

struct NIMLQuickLookReaderTests {
    private func read(_ text: String) throws -> NIMLPreviewModel {
        try NIMLQuickLookReader.read(data: Data(text.utf8))
    }

    @Test func readsDatasetMetadataAndSparseRows() throws {
        let model = try read("""
        <?xml version="1.0"?>
        <AFNI_dataset ni_form="ni_group" dset_type="Node_Bucket" domain_parent_idcode label='a > b'>
          <!-- AFNI metadata -->
          <AFNI_atr ni_type="String" ni_dimen="1" atr_name="COLMS_LABS">"effect;T &amp; score;"</AFNI_atr>
          <INDEX_LIST ni_type="int" ni_dimen="2">10 42</INDEX_LIST>
          <SPARSE_DATA ni_type="2*float" ni_dimen="2" ni_timestep="1.5">1 -2 3 4</SPARSE_DATA>
        </AFNI_dataset>
        """)
        #expect(model.dataset?.attributes["domain_parent_idcode"] == "")
        #expect(model.dataset?.attributes["label"] == "a > b")
        #expect(model.columnLabels == ["effect", "T & score", ""])
        #expect(model.data?.rows == 2)
        #expect(model.data?.sample == [["1", "-2"], ["3", "4"]])
        #expect(model.data?.ranges == [1...3, -2...4])
        #expect(model.elements[2].sample == [["10"], ["42"]])
    }

    @Test func binaryAndBase64ByteOrders() throws {
        for little in [true, false] {
            for base64 in [true, false] {
                var payload = Data()
                for (number, index) in [(Float(1.5), Int32(-10)), (Float(-2.5), Int32(42))] {
                    for bits in [number.bitPattern, UInt32(bitPattern: index)] {
                        for offset in 0..<4 {
                            payload.append(UInt8(truncatingIfNeeded: bits >> ((little ? offset : 3 - offset) * 8)))
                        }
                    }
                }
                // The unqualified binary form must default to big-endian.
                let form = (base64 ? "base64" : "binary") + (little ? ".lsbfirst" : "")
                var data = Data("<SPARSE_DATA ni_type='float,int' ni_dimen='2' ni_form='\(form)'>".utf8)
                data.append(base64 ? Data(("\n" + payload.base64EncodedString() + "\n").utf8) : payload)
                data.append(Data("</SPARSE_DATA>".utf8))
                let model = try NIMLQuickLookReader.read(data: data)
                #expect(model.data?.sample == [["1.5", "-10.0"], ["-2.5", "42.0"]])
                #expect(model.data?.ranges == [-2.5...1.5, -10...42])
            }
        }
    }

    @Test func binaryBodyIsNotSearchedForClosingTagsOrTrimmed() throws {
        let payload = Data(" </VALUES>\n".utf8)
        var data = Data("<VALUES ni_type='byte' ni_dimen='\(payload.count)' ni_form='binary'>".utf8)
        data.append(payload)
        data.append(Data("</VALUES><EMPTY/>".utf8))
        let model = try NIMLQuickLookReader.read(data: data)
        #expect(model.elements.count == 2)
        #expect(model.elements[0].rows == payload.count)
        #expect(model.elements[0].sample.first == ["32.0"])
    }

    @Test func readsGenericMixedTablesAndEntities() throws {
        let model = try read("""
        <GROUP ni_form='ni_group'><MIXED ni_type='int,String,double' ni_dimen='2'>
        1 "alpha beta" 2.5
        2 'a&#32;b &amp;lt;' nan
        </MIXED><NOTE>hello &lt; world</NOTE></GROUP>
        """)
        #expect(model.elements[1].sample[1] == ["2", "a b &lt;", "nan"])
        #expect(model.elements[1].ranges[2] == 2.5...2.5)
        #expect(model.elements[2].text == "hello < world")
    }

    @Test func boundsSamplesButComputesCompleteRanges() throws {
        let body = (0..<25).map { String($0) }.joined(separator: " ")
        let model = try read("<X ni_type='float' ni_dimen='25'>\(body)</X>")
        #expect(model.elements[0].sample.count == 20)
        #expect(model.elements[0].rows == 25)
        #expect(model.elements[0].ranges == [0...24])
    }

    @Test func joinsSplitStringAttributes() throws {
        let model = try read("""
        <AFNI_dataset ni_form='ni_group'>
        <AFNI_atr ni_type='String' ni_dimen='2' atr_name='COLMS_LABS'>"first;" "second;"</AFNI_atr>
        </AFNI_dataset>
        """)
        #expect(model.columnLabels == ["first", "second", ""])
    }

    @Test func rejectsMalformedAndExcessiveInputs() {
        for text in ["", "<X>", "<G ni_form='ni_group'></X>",
                     "<X ni_type='2*float' ni_dimen='2'>1 2 3</X>",
                     "<X ni_type='float' ni_dimen='-1'>1</X>",
                     "<X ni_type='999999999999*float'>1</X>",
                     "<X ni_type='float' ni_dimen='999999999999999999999' ni_form='binary'></X>",
                     "<X ni_type='float' ni_dimen='2' ni_form='binary'>a</X>",
                     "<X ni_type='float' ni_dimen='1' ni_form='base64'>%%%%</X>",
                     "<X ni_type='CString' ni_dimen='1' ni_form='binary'>abc</X>"] {
            #expect(throws: NIMLReadError.self) { try read(text) }
        }
    }

    @Test func routesNIMLAndCompoundDatasetExtensions() throws {
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "/tmp/test.NIML")) == .niml)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "/tmp/lh.test.NIML.DSET")) == .niml)
        #expect(EVAPreviewFormat.identify(URL(fileURLWithPath: "/tmp/unrelated.dset")) == nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".niml.dset")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("<NOTE>file reader</NOTE>".utf8).write(to: url)
        #expect(try NIMLQuickLookReader.read(from: url).fileName == url.lastPathComponent)
    }
}
