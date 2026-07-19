import Foundation
import Testing
@testable import VMDCore

@Suite("RayClusterStatus")
struct RayClusterStatusTests {
    static let twoNodeFixture = """
    ======== Autoscaler status: 2026-07-19 12:00:00.000000 ========
    Node status
    ---------------------------------------------------------------
    Active:
     1 node_1f0c89a4
     1 node_9b2d11ce
    Pending:
     (no pending nodes)
    Recent failures:
     (no failures)

    Resources
    ---------------------------------------------------------------
    Usage:
     0.0/24.0 CPU
     1.0/2.0 mlx
     0B/40.00GiB memory
     0B/18.63GiB object_store_memory
    """

    @Test("parses active nodes and the mlx resource")
    func parsesFixture() throws {
        let status = try #require(RayClusterStatus.parse(Self.twoNodeFixture))
        #expect(status.activeNodes == 2)
        #expect(status.mlxTotal == 2)
        #expect(status.mlxUsed == 1)
    }

    @Test("a cluster without the mlx resource parses with zero mlx")
    func noMLXResource() throws {
        let fixture = Self.twoNodeFixture.replacingOccurrences(of: " 1.0/2.0 mlx\n", with: "")
        let status = try #require(RayClusterStatus.parse(fixture))
        #expect(status.activeNodes == 2)
        #expect(status.mlxTotal == 0)
    }

    @Test("non-status output is rejected")
    func rejectsGarbage() {
        #expect(RayClusterStatus.parse("Ray is not running on this node") == nil)
        #expect(RayClusterStatus.parse("") == nil)
    }

    @Test("ray --version output parses to the bare version")
    func parseVersion() {
        #expect(RayCluster.parseVersion("ray, version 2.44.0") == "2.44.0")
        #expect(RayCluster.parseVersion("ray, version 3.0.0.dev0\n") == "3.0.0.dev0")
        #expect(RayCluster.parseVersion("command not found") == nil)
    }
}
