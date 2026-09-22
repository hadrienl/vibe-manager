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

  @Test("The same folder typed in another case is the same guarded folder")
  func matchingIgnoresCase() {
    // The volume these live on keeps no case, so `~/documents` opens Documents. A warning lost to
    // a lowercase letter is a warning that failed.
    #expect(covering("/Users/tester/documents/notes") == .documents)
    #expect(covering("/users/tester/Desktop") == .desktop)
    #expect(covering("/Users/tester/library/mobile documents") == .iCloudDrive)
  }

  @Test("The startup disk reached through /Volumes is not an external volume")
  func theBootVolumeIsNotExternal() {
    // macOS firmlinks the startup volume into /Volumes under its own name: the very same folder,
    // announced as external unless someone asks which volume it is.
    let boot = "/Volumes/Macintosh HD"
    #expect(covering(boot + "/Users/tester/Code", bootMount: boot) == nil)
    #expect(covering("/Volumes/Backup/repo", bootMount: boot) == .externalVolume)
  }

  private func covering(
    _ path: String,
    bootMount: String? = nil
  ) -> ProtectedFileLocation? {
    ProtectedFileLocation.covering(
      path: path,
      homeDirectoryPath: home,
      isBootVolumeMount: { $0 == bootMount }
    )
  }
}
