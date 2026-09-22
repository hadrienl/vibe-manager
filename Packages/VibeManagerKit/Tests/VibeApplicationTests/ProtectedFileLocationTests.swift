import Testing
import VibeApplication

@Suite("Recognising a folder macOS guards")
struct ProtectedFileLocationTests {
  private let home = "/Users/tester"

  @Test("The guarded folders are recognised, and so is anything inside them")
  func protectedFoldersAreRecognised() {
    #expect(covering("/Users/tester/Desktop") == .desktop)
    #expect(covering("/Users/tester/Documents/notes") == .documents)
    #expect(covering("/Users/tester/Downloads/archive/inner") == .downloads)
    #expect(covering("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs") == .iCloudDrive)
    #expect(covering("/Volumes/Backup/repo") == .externalVolume)
  }

  @Test("An ordinary repository is not guarded, which is why refusing works")
  func ordinaryFoldersAreNotProtected() {
    #expect(covering("/Users/tester/Code/vibe-manager") == nil)
    #expect(covering("/Users/tester") == nil)
    #expect(covering("/tmp/scratch") == nil)
  }

  @Test("A name that merely starts the same way is not the guarded folder")
  func neighbouringNamesAreNotMatched() {
    #expect(covering("/Users/tester/Documentation") == nil)
    #expect(covering("/Users/tester/DesktopBackup") == nil)
  }

  private func covering(_ path: String) -> ProtectedFileLocation? {
    ProtectedFileLocation.covering(path: path, homeDirectoryPath: home)
  }
}
