import DJCDomain
import Foundation
import RekordboxKit
import Testing

/// USB 값 모델을 RekordboxKit에서 DJCDomain으로 옮겨도(#167) 저널·report.json·보고 JSON의 키와 값 모양이 그대로인지 본다.
/// 기대 문자열은 옮기기 전 RekordboxKit 정의로 인코딩한 결과다.
@Suite("USB 값 모델 인코딩 고정")
struct UsbModelEncodingTests {
    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static let date = Date(timeIntervalSince1970: 1_700_000_000.25)

    static var changes: UsbChangeSet {
        let draft = UsbSyncSelectionDraft(localDBID: 7, sourceNodes: [UsbSyncSourceNode(id: "s1", parentID: nil, isFolder: false, timestamp: 3)],
                                          selection: ITunesSyncSelection(selectedIDs: ["s1"]), enabled: true,
                                          playlistRefs: [:], baseFiles: [.oneLibrary: Data([1, 2])])
        return UsbChangeSet(
            session: "abcdefgh", label: "t", purpose: .edit, formats: [.oneLibrary], requiredRules: [.artworkMissing],
            databases: [UsbDatabaseReplacement(format: .oneLibrary, destination: "PIONEER/rekordbox/exportLibrary.db", staged: "s/db",
                                               sha256: "aa", size: 10)],
            copies: [UsbFileCopy(source: "/tmp/a.mp3", destination: "Contents/a.mp3", size: 5, sourceSHA1: "bb", modificationDate: date,
                                 disposition: .create)],
            writes: [UsbFileWrite(staged: "s/w", destination: "PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT", sha256: "cc", size: 6,
                                  modificationDate: nil, disposition: .overwrite, expectedExistingPPTH: "p", expectedExistingSHA256: "dd",
                                  afterDatabases: true)],
            removals: [UsbFileRemoval(path: "Contents/b.mp3", expectedSHA256: "ee", expectedSize: 4, expectedPPTH: nil,
                                      localOriginal: "/tmp/b.mp3", localOriginalSHA1: "ff")],
            base: UsbFingerprint(files: ["PIONEER/rekordbox/exportLibrary.db": .init(size: 9, mtime: date, sha256: "11")]),
            target: UsbTargetFingerprint(mustExist: ["a": UsbTreeStamp(size: 1, sha256: "00"), "b": UsbTreeStamp(size: 2, sha256: nil)],
                                         mustNotExist: ["c"]),
            stagingDirectory: "/tmp/x", idHighWater: ["content": 7],
            syncSelection: UsbSyncSelectionVerification(draft: draft, formats: [.oneLibrary], playlistIDs: [.oneLibrary: ["s1": 4]],
                                                        contract: UsbSyncXMLWriteContract(revision: 1)))
    }

    @Test("변경 묶음(저널에 그대로 들어간다)")
    func changeSet() throws {
        #expect(try Self.json(Self.changes) == Self.expectedChangeSet)
        #expect(try JSONDecoder().decode(UsbChangeSet.self, from: Data(Self.expectedChangeSet.utf8)) == Self.changes)
    }

    @Test("저널 전체(UsbJournal.encoder)")
    func journal() throws {
        let journal = UsbJournal(changes: Self.changes, volumeUUID: "00000000-0000-0000-0000-000000000001", volumeName: "DJCTEST",
                                 now: Self.date)
        let data = try UsbJournal.encoder().encode(journal)
        #expect(String(decoding: data, as: UTF8.self) == Self.expectedJournal)
        #expect(try UsbJournal.decoder().decode(UsbJournal.self, from: data) == journal)
    }

    @Test("쓰기 보고(report.json)")
    func writeReport() throws {
        let report = UsbWriteReport(outcome: .written, session: "abcdefgh", backup: "/tmp/b", resultDatabases: ["x": "aa"], filesCreated: 1,
                                    filesReused: 2, filesOverwritten: 3, filesRemoved: 4, appleDoubleRemoved: 5,
                                    blocks: [UsbBlock(code: "c", scope: .track("usb:3"), message: "m", rule: .artworkMissing)], notes: ["n"])
        #expect(try Self.json(report) == Self.expectedWriteReport)
        let all: [UsbWriteReport.Outcome] = [.dryRun, .written, .rolledBack, .restoreFailed, .restorePending, .recovered, .restored, .needsReplan]
        #expect(try Self.json(all) == #"["dryRun","written","rolledBack","restoreFailed","restorePending","recovered","restored","needsReplan"]"#)
    }

    @Test("편집 결과·USB property·단계 이름")
    func smallValues() throws {
        let outcomes: [UsbOutcome] = [.written, .unchanged, .blocked(UsbBlock(code: "c", scope: .volume, message: "m")), .deferred("d")]
        #expect(try Self.json(outcomes) == Self.expectedOutcomes)
        let property = UsbProperty(deviceName: "n", dbVersion: "1000", numberOfContents: 2, createdDate: "2026-10-09", backgroundColorType: 1,
                                   myTagMasterDBID: 4_294_967_295, pdbDate: "2026-10-08", pdbDeviceName: nil)
        #expect(try Self.json(property) == Self.expectedProperty)
        #expect(try Self.json(UsbWriteStage.allCases)
            == #"["precheck","staged","backedUp","files","commitOneLibrary","commitExport","commitExportExt","cleaned","verified"]"#)
        let phases: [UsbProgress.Phase] = [.planning, .staging, .backup, .files, .commit, .cleanup, .verify, .restore, .recover]
        #expect(try Self.json(phases) == #"["planning","staging","backup","files","commit","cleanup","verify","restore","recover"]"#)
        #expect(try Self.json([UsbDisposition.create, .overwrite, .reuse]) == #"["create","overwrite","reuse"]"#)
    }

    static let expectedChangeSet = #"{"base":{"files":{"PIONEER\/rekordbox\/exportLibrary.db":{"mtime":721692800.25,"sha256":"11","size":9}}},"copies":[{"destination":"Contents\/a.mp3","disposition":"create","modificationDate":721692800.25,"size":5,"source":"\/tmp\/a.mp3","sourceSHA1":"bb"}],"databases":[{"destination":"PIONEER\/rekordbox\/exportLibrary.db","format":"oneLibrary","sha256":"aa","size":10,"staged":"s\/db"}],"formats":["oneLibrary"],"idHighWater":{"content":7},"label":"t","purpose":"edit","removals":[{"expectedSHA256":"ee","expectedSize":4,"localOriginal":"\/tmp\/b.mp3","localOriginalSHA1":"ff","path":"Contents\/b.mp3"}],"requiredRules":["artworkMissing"],"session":"abcdefgh","stagingDirectory":"\/tmp\/x","syncSelection":{"contract":{"revision":1},"draft":{"baseFiles":["oneLibrary","AQI="],"enabled":true,"enabledOnly":false,"localDBID":7,"playlistRefs":{},"selection":{"selectedIDs":["s1"]},"skippedTracks":[],"sourceNodes":[{"id":"s1","isFolder":false,"timestamp":3}]},"formats":["oneLibrary"],"playlistIDs":["oneLibrary",{"s1":4}]},"target":{"mustExist":{"a":{"sha256":"00","size":1},"b":{"size":2}},"mustNotExist":["c"]},"writes":[{"afterDatabases":true,"destination":"PIONEER\/USBANLZ\/P000\/00000001\/ANLZ0000.DAT","disposition":"overwrite","expectedExistingPPTH":"p","expectedExistingSHA256":"dd","sha256":"cc","size":6,"staged":"s\/w"}]}"#
    static let expectedJournal = #"""
        {
          "changes" : {
            "base" : {
              "files" : {
                "PIONEER\/rekordbox\/exportLibrary.db" : {
                  "mtime" : 721692800.25,
                  "sha256" : "11",
                  "size" : 9
                }
              }
            },
            "copies" : [
              {
                "destination" : "Contents\/a.mp3",
                "disposition" : "create",
                "modificationDate" : 721692800.25,
                "size" : 5,
                "source" : "\/tmp\/a.mp3",
                "sourceSHA1" : "bb"
              }
            ],
            "databases" : [
              {
                "destination" : "PIONEER\/rekordbox\/exportLibrary.db",
                "format" : "oneLibrary",
                "sha256" : "aa",
                "size" : 10,
                "staged" : "s\/db"
              }
            ],
            "formats" : [
              "oneLibrary"
            ],
            "idHighWater" : {
              "content" : 7
            },
            "label" : "t",
            "purpose" : "edit",
            "removals" : [
              {
                "expectedSHA256" : "ee",
                "expectedSize" : 4,
                "localOriginal" : "\/tmp\/b.mp3",
                "localOriginalSHA1" : "ff",
                "path" : "Contents\/b.mp3"
              }
            ],
            "requiredRules" : [
              "artworkMissing"
            ],
            "session" : "abcdefgh",
            "stagingDirectory" : "\/tmp\/x",
            "syncSelection" : {
              "contract" : {
                "revision" : 1
              },
              "draft" : {
                "baseFiles" : [
                  "oneLibrary",
                  "AQI="
                ],
                "enabled" : true,
                "enabledOnly" : false,
                "localDBID" : 7,
                "playlistRefs" : {

                },
                "selection" : {
                  "selectedIDs" : [
                    "s1"
                  ]
                },
                "skippedTracks" : [

                ],
                "sourceNodes" : [
                  {
                    "id" : "s1",
                    "isFolder" : false,
                    "timestamp" : 3
                  }
                ]
              },
              "formats" : [
                "oneLibrary"
              ],
              "playlistIDs" : [
                "oneLibrary",
                {
                  "s1" : 4
                }
              ]
            },
            "target" : {
              "mustExist" : {
                "a" : {
                  "sha256" : "00",
                  "size" : 1
                },
                "b" : {
                  "size" : 2
                }
              },
              "mustNotExist" : [
                "c"
              ]
            },
            "writes" : [
              {
                "afterDatabases" : true,
                "destination" : "PIONEER\/USBANLZ\/P000\/00000001\/ANLZ0000.DAT",
                "disposition" : "overwrite",
                "expectedExistingPPTH" : "p",
                "expectedExistingSHA256" : "dd",
                "sha256" : "cc",
                "size" : 6,
                "staged" : "s\/w"
              }
            ]
          },
          "createdDirs" : [

          ],
          "databases" : [

          ],
          "deletedSidecars" : [

          ],
          "entries" : [

          ],
          "formatVersion" : 1,
          "nextSequence" : 1,
          "plannedDatabases" : [

          ],
          "removals" : [

          ],
          "restoringBackup" : false,
          "state" : "planned",
          "updatedAt" : 721692800.25,
          "volumeName" : "DJCTEST",
          "volumeUUID" : "00000000-0000-0000-0000-000000000001"
        }
        """#
    static let expectedWriteReport = #"{"appleDoubleRemoved":5,"backup":"\/tmp\/b","blocks":[{"code":"c","message":"m","rule":"artworkMissing","scope":{"track":{"_0":"usb:3"}}}],"filesCreated":1,"filesOverwritten":3,"filesRemoved":4,"filesReused":2,"notes":["n"],"outcome":"written","resultDatabases":{"x":"aa"},"session":"abcdefgh"}"#
    static let expectedOutcomes = #"[{"written":{}},{"unchanged":{}},{"blocked":{"_0":{"code":"c","message":"m","scope":{"volume":{}}}}},{"deferred":{"_0":"d"}}]"#
    static let expectedProperty = #"{"backgroundColorType":1,"createdDate":"2026-10-09","dbVersion":"1000","deviceName":"n","myTagMasterDBID":4294967295,"numberOfContents":2,"pdbDate":"2026-10-08"}"#
}
