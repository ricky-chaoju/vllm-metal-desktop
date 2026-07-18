import Foundation
import Testing
@testable import VMDCore

@Suite("GitHubReleaseClient")
struct GitHubReleaseTests {
    // A trimmed but realistic `releases/latest` payload.
    let fixture = """
    {
      "tag_name": "v0.3.0.dev20260620073347",
      "name": "0.3.0.dev20260620073347",
      "assets": [
        {
          "name": "vllm_metal-0.3.0.dev20260620073347-cp313-cp313-macosx_15_0_arm64.whl",
          "browser_download_url": "https://github.com/vllm-project/vllm-metal/releases/download/v0.3.0.dev20260620073347/vllm_metal-0.3.0.dev20260620073347-cp313-cp313-macosx_15_0_arm64.whl"
        },
        {
          "name": "vllm_metal-0.3.0.dev20260620073347-cp312-cp312-macosx_15_0_arm64.whl",
          "browser_download_url": "https://github.com/vllm-project/vllm-metal/releases/download/v0.3.0.dev20260620073347/vllm_metal-0.3.0.dev20260620073347-cp312-cp312-macosx_15_0_arm64.whl"
        },
        {
          "name": "Source code (tar.gz)",
          "browser_download_url": "https://github.com/vllm-project/vllm-metal/archive/refs/tags/v0.3.0.dev20260620073347.tar.gz"
        }
      ]
    }
    """.data(using: .utf8)!

    @Test("parses tag into an EngineVersion")
    func parseTag() throws {
        let info = try GitHubReleaseClient.parse(fixture)
        #expect(info.tag == "v0.3.0.dev20260620073347")
        #expect(info.version == EngineVersion("0.3.0.dev20260620073347"))
        #expect(info.assets.count == 3)
    }

    @Test("picks the cp312 arm64 wheel")
    func picksMatchingWheel() throws {
        let info = try GitHubReleaseClient.parse(fixture)
        let url = info.wheelURL(pythonTag: "cp312")
        #expect(url?.absoluteString.contains("cp312-cp312-macosx_15_0_arm64.whl") == true)
    }

    @Test("falls back to any arm64 wheel for an unknown python tag")
    func fallbackWheel() throws {
        let info = try GitHubReleaseClient.parse(fixture)
        let url = info.wheelURL(pythonTag: "cp399")
        #expect(url?.absoluteString.hasSuffix(".whl") == true)
        #expect(url?.absoluteString.contains("arm64") == true)
    }

    @Test("latest release URL is well-formed")
    func releaseURL() {
        let client = GitHubReleaseClient()
        #expect(client.latestReleaseURL.absoluteString
            == "https://api.github.com/repos/vllm-project/vllm-metal/releases/latest")
    }

    @Test("installed-version parsing trims and takes the last line")
    func installedParse() {
        #expect(InstalledEngine.parseVersion("0.3.0.dev20260620073347\n")
            == EngineVersion("0.3.0.dev20260620073347"))
        // Tolerate a warning line printed before the version.
        #expect(InstalledEngine.parseVersion("some warning\n0.3.0\n") == EngineVersion("0.3.0"))
        #expect(InstalledEngine.parseVersion("  0.4.0  ") == EngineVersion("0.4.0"))
    }

    // MARK: Release list + generated notes

    // A trimmed but realistic `releases?per_page=N` payload (newest first).
    let listFixture = """
    [
      {
        "tag_name": "v0.3.0.dev20260716042225",
        "html_url": "https://github.com/vllm-project/vllm-metal/releases/tag/v0.3.0.dev20260716042225",
        "published_at": "2026-07-16T04:22:39Z",
        "prerelease": false,
        "body": "## What's Changed\\n* Wire up --gpu-memory-utilization on the Metal paged KV path by @mhdimo in https://github.com/vllm-project/vllm-metal/pull/514\\n\\n## New Contributors\\n* @mhdimo made their first contribution in https://github.com/vllm-project/vllm-metal/pull/514\\n\\n**Full Changelog**: https://github.com/vllm-project/vllm-metal/compare/a...b",
        "assets": [
          {
            "name": "vllm_metal-0.3.0.dev20260716042225-cp312-cp312-macosx_11_0_arm64.whl",
            "browser_download_url": "https://github.com/vllm-project/vllm-metal/releases/download/v0.3.0.dev20260716042225/vllm_metal-0.3.0.dev20260716042225-cp312-cp312-macosx_11_0_arm64.whl"
          }
        ]
      },
      {
        "tag_name": "v0.3.0.dev20260716041542",
        "html_url": "https://github.com/vllm-project/vllm-metal/releases/tag/v0.3.0.dev20260716041542",
        "published_at": "2026-07-16T04:15:56Z",
        "prerelease": false,
        "body": "## What's Changed\\n* Route PP dummy forwards through the stage shape by @ricky-chaoju in https://github.com/vllm-project/vllm-metal/pull/504\\n* Fail fast on model warm-up errors by @LxYuan0420 in https://github.com/vllm-project/vllm-metal/pull/510\\n* Another fix by @ricky-chaoju in https://github.com/vllm-project/vllm-metal/pull/511",
        "assets": []
      }
    ]
    """.data(using: .utf8)!

    @Test("parses a release list newest-first with dates and versions")
    func parseListBasics() throws {
        let releases = try GitHubReleaseClient.parseList(listFixture)
        #expect(releases.count == 2)
        #expect(releases[0].tag == "v0.3.0.dev20260716042225")
        #expect(releases[0].version == EngineVersion("0.3.0.dev20260716042225"))
        #expect(releases[0].publishedAt != nil)
        #expect(releases[0].isPrerelease == false)
        #expect(releases[0].wheelURL(pythonTag: "cp312") != nil)
    }

    @Test("extracts changes with summary, author, and PR URL from generated notes")
    func parseChanges() throws {
        let releases = try GitHubReleaseClient.parseList(listFixture)
        let changes = releases[1].changes
        #expect(changes.count == 3)
        #expect(changes[0].summary == "Route PP dummy forwards through the stage shape")
        #expect(changes[0].author == "ricky-chaoju")
        #expect(changes[0].pullRequestURL?.absoluteString.hasSuffix("/pull/504") == true)
        #expect(changes[1].author == "LxYuan0420")
    }

    @Test("contributors are unique, in first-appearance order, skipping the New Contributors section")
    func contributors() throws {
        let releases = try GitHubReleaseClient.parseList(listFixture)
        #expect(releases[1].contributors == ["ricky-chaoju", "LxYuan0420"])
        // The "New Contributors" bullet (`* @mhdimo made their first…`) is not a change.
        #expect(releases[0].contributors == ["mhdimo"])
        #expect(releases[0].changes.count == 1)
    }

    @Test("notes parsing tolerates hand-written bullets and blank notes")
    func parseChangesEdgeCases() {
        #expect(GitHubReleaseClient.parseChanges(fromNotes: "").isEmpty)
        // A hand-written bullet without attribution is skipped, authored ones kept.
        let notes = """
        * Fixed a thing
        - Improve docs by @alice in https://github.com/x/y/pull/1
        """
        let changes = GitHubReleaseClient.parseChanges(fromNotes: notes)
        #expect(changes.count == 1)
        #expect(changes[0].author == "alice")
    }

    @Test("identical titles by one author in one release keep distinct identities")
    func changeIdentity() {
        let notes = """
        * Fix CI by @alice in https://github.com/x/y/pull/510
        * Fix CI by @alice in https://github.com/x/y/pull/517
        """
        let changes = GitHubReleaseClient.parseChanges(fromNotes: notes)
        #expect(changes.count == 2)
        #expect(Set(changes.map(\.id)).count == 2)
    }

    @Test("link tokens are sanitized: punctuation stripped, non-URLs and fragments rejected")
    func linkSanitization() {
        func url(_ token: String) -> URL? {
            GitHubReleaseClient.parseChanges(fromNotes: "* Fix by @a in \(token)").first?.pullRequestURL
        }
        // Trailing sentence punctuation is shed.
        #expect(url("https://github.com/x/y/pull/12.")?.absoluteString == "https://github.com/x/y/pull/12")
        // A bare "#123" is not an openable URL.
        #expect(url("#123") == nil)
        // Only http(s) survives.
        #expect(url("ftp://example.com/pull/9") == nil)
    }

    @Test("pullRequestNumber only for conventional /pull/<n> URLs")
    func prNumber() {
        let notes = """
        * A by @a in https://github.com/x/y/pull/504
        * B by @b in https://github.com/x/y/compare/v1...v2
        """
        let changes = GitHubReleaseClient.parseChanges(fromNotes: notes)
        #expect(changes[0].pullRequestNumber == 504)
        #expect(changes[1].pullRequestNumber == nil)  // valid URL, but not a PR link
        #expect(changes[1].pullRequestURL != nil)
    }

    @Test("errors read as sentences, not enum dumps")
    func errorText() {
        #expect(GitHubReleaseError.httpStatus(403).errorDescription
            == "GitHub API rate limit reached — try again in a few minutes.")
        #expect(GitHubReleaseError.httpStatus(500).errorDescription == "GitHub returned HTTP 500.")
        #expect(GitHubReleaseError.notHTTP.errorDescription == "Unexpected response from GitHub.")
    }

    @Test("releases list URL is well-formed")
    func releasesListURL() {
        let client = GitHubReleaseClient()
        #expect(client.releasesURL(count: 10).absoluteString
            == "https://api.github.com/repos/vllm-project/vllm-metal/releases?per_page=10")
    }

    @Test("docs listing keeps markdown files, in reading order, well titled")
    func docEntries() throws {
        let payload = """
        [
          {"name": "turboquant.md", "type": "file", "download_url": "https://raw.githubusercontent.com/x/y/main/docs/turboquant.md"},
          {"name": "images", "type": "dir", "download_url": null},
          {"name": "index.md", "type": "file", "download_url": "https://raw.githubusercontent.com/x/y/main/docs/index.md"},
          {"name": "sglang_deploy_guide.md", "type": "file", "download_url": "https://raw.githubusercontent.com/x/y/main/docs/sglang_deploy_guide.md"},
          {"name": "installation.md", "type": "file", "download_url": "https://raw.githubusercontent.com/x/y/main/docs/installation.md"},
          {"name": "diagram.png", "type": "file", "download_url": "https://raw.githubusercontent.com/x/y/main/docs/diagram.png"}
        ]
        """.data(using: .utf8)!
        let entries = try GitHubReleaseClient.parseDocEntries(payload)
        // Curated reading order first (index → installation → …), unknowns after.
        #expect(entries.map(\.name)
            == ["index.md", "installation.md", "turboquant.md", "sglang_deploy_guide.md"])
        #expect(entries[0].title == "Overview")
        #expect(entries[3].title == "SGLang Deploy Guide")
    }

    @Test("parses the pinned vLLM base out of install.sh")
    func vllmBaseParsing() {
        let script = """
        install_vllm() {
          local vllm_v="0.25.1"
          local url_base="https://github.com/vllm-project/vllm/releases/download"
        }
        """
        #expect(GitHubReleaseClient.parseVLLMBase(fromInstallScript: script) == EngineVersion("0.25.1"))
        #expect(GitHubReleaseClient.parseVLLMBase(fromInstallScript: "no pin here") == nil)
    }

    @Test("core rebuild needed exactly when the release targets a different compiled base")
    func coreRebuildDecision() {
        let v24 = EngineVersion("0.24.0")
        let v25 = EngineVersion("0.25.1")
        #expect(EngineInstaller.needsCoreRebuild(requiredBase: v25, installedCore: v24))
        #expect(!EngineInstaller.needsCoreRebuild(requiredBase: v25, installedCore: v25))
        // Unknown either side → don't force the slow path; verify-step catches breakage.
        #expect(!EngineInstaller.needsCoreRebuild(requiredBase: nil, installedCore: v24))
        #expect(!EngineInstaller.needsCoreRebuild(requiredBase: v25, installedCore: nil))
    }
}
