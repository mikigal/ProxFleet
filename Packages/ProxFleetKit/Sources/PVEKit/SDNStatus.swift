import Foundation
import ProxmoxCore

/// An SDN zone or fabric on a node, as `/cluster/resources` lists them (`type` `network`), like the web interface's
/// resource tree. Every node also has the zone `localnetwork` for its own bridges. Before PVE 9.1 only zones are
/// listed, with `type` `sdn`.
public struct SDNNodeNetwork: Decodable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case zone, fabric
    }

    public var node: String
    public var name: String
    public var kind: Kind?
    /// `ok`, `available`, `pending`, `error`…
    public var status: String
    /// Zones: like `evpn` or `vlan`.
    public var zoneType: String?
    /// Fabrics: like `openfabric` or `ospf`.
    public var fabricProtocol: String?

    public var id: String { "\(node)/\(kind?.rawValue ?? "")/\(name)" }
    public var isLocalNetwork: Bool { kind == .zone && name == "localnetwork" }

    public init(node: String, name: String, kind: Kind?, status: String = "ok", zoneType: String? = nil, fabricProtocol: String? = nil) {
        self.node = node
        self.name = name
        self.kind = kind
        self.status = status
        self.zoneType = zoneType
        self.fabricProtocol = fabricProtocol
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        node = container.lossyString(AnyCodingKey("node")) ?? ""
        name = container.lossyString(AnyCodingKey("network")) ?? container.lossyString(AnyCodingKey("sdn")) ?? ""
        kind = container.lossyString(AnyCodingKey("network-type")).flatMap(Kind.init)
            ?? (container.lossyString(AnyCodingKey("type")) == "sdn" ? .zone : nil)
        status = container.lossyString(AnyCodingKey("status")) ?? ""
        zoneType = container.lossyString(AnyCodingKey("zone-type"))
        fabricProtocol = container.lossyString(AnyCodingKey("protocol"))
    }
}

/// `GET /nodes/{node}/sdn/zones/{zone}/content`: a VNet of the zone and whether it works on the node.
public struct SDNZoneContentEntry: Decodable, Sendable, Equatable, Identifiable {
    public var vnet: String
    public var status: String?
    public var statusMessage: String?

    public var id: String { vnet }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        vnet = container.lossyString(AnyCodingKey("vnet")) ?? ""
        status = container.lossyString(AnyCodingKey("status"))
        statusMessage = container.lossyString(AnyCodingKey("statusmsg"))
    }
}

/// `GET /nodes/{node}/sdn/zones/{zone}/bridges`: a bridge of the zone with what is plugged into it.
public struct SDNBridge: Decodable, Sendable, Equatable, Identifiable {
    public struct Port: Decodable, Sendable, Equatable, Identifiable {
        public var name: String
        /// The guest the port belongs to, nil for physical ports.
        public var vmid: Int?
        /// The guest's network device, like `net0`.
        public var device: String?
        public var primaryVLAN: Int?
        /// VLANs and ranges like `100-200`.
        public var vlans: [String]

        public var id: String { name }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyCodingKey.self)
            name = container.lossyString(AnyCodingKey("name")) ?? ""
            vmid = container.lossyInt(AnyCodingKey("vmid"))
            device = container.lossyString(AnyCodingKey("index"))
            primaryVLAN = container.lossyInt(AnyCodingKey("primary_vlan"))
            vlans = ((try? container.decodeIfPresent([AnyDecodable].self, forKey: AnyCodingKey("vlans"))) ?? []).compactMap(\.string)
        }
    }

    public var name: String
    public var isVLANAware: Bool
    public var ports: [Port]

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        isVLANAware = container.lossyBool(AnyCodingKey("vlan_filtering")) ?? false
        ports = ((try? container.decodeIfPresent([Port].self, forKey: AnyCodingKey("ports"))) ?? [])
            // Guests' ports by guest, then the physical ones.
            .sorted { ($0.vmid ?? Int.max, $0.name) < ($1.vmid ?? Int.max, $1.name) }
    }
}

/// `GET /nodes/{node}/sdn/zones/{zone}/ip-vrf`: a route of an EVPN zone's VRF on the node.
public struct SDNIPVRFRoute: Decodable, Sendable, Equatable, Identifiable {
    public var prefix: String
    public var protocolName: String?
    public var metric: Int?
    public var nexthops: [String]

    public var id: String { prefix + nexthops.joined() }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        prefix = container.lossyString(AnyCodingKey("ip")) ?? ""
        protocolName = container.lossyString(AnyCodingKey("protocol"))
        metric = container.lossyInt(AnyCodingKey("metric"))
        nexthops = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("nexthops"))) ?? []
    }
}

/// `GET /nodes/{node}/sdn/vnets/{vnet}/mac-vrf`: a MAC address the VNet knows, and where it is.
public struct SDNMACVRFEntry: Decodable, Sendable, Equatable, Identifiable {
    public var mac: String
    public var ip: String?
    public var nexthop: String?

    public var id: String { mac + (ip ?? "") }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        mac = container.lossyString(AnyCodingKey("mac")) ?? ""
        ip = container.lossyString(AnyCodingKey("ip"))
        nexthop = container.lossyString(AnyCodingKey("nexthop"))
    }
}

/// `GET /nodes/{node}/sdn/fabrics/{fabric}/routes`.
public struct SDNFabricRoute: Decodable, Sendable, Equatable, Identifiable {
    public var route: String
    public var via: [String]

    public var id: String { route }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        route = container.lossyString(AnyCodingKey("route")) ?? ""
        via = (try? container.decodeIfPresent([String].self, forKey: AnyCodingKey("via"))) ?? []
    }
}

/// `GET /nodes/{node}/sdn/fabrics/{fabric}/neighbors`, as FRR reports them.
public struct SDNFabricNeighbor: Decodable, Sendable, Equatable, Identifiable {
    public var neighbor: String
    public var status: String?
    /// Like `8h24m12s`.
    public var uptime: String?

    public var id: String { neighbor }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        neighbor = container.lossyString(AnyCodingKey("neighbor")) ?? ""
        status = container.lossyString(AnyCodingKey("status"))
        uptime = container.lossyString(AnyCodingKey("uptime"))
    }
}

/// `GET /nodes/{node}/sdn/fabrics/{fabric}/interfaces`.
public struct SDNFabricInterfaceStatus: Decodable, Sendable, Equatable, Identifiable {
    public var name: String
    public var state: String?
    /// Like `Point-to-Point` or `Broadcast`.
    public var type: String?

    public var id: String { name }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        name = container.lossyString(AnyCodingKey("name")) ?? ""
        state = container.lossyString(AnyCodingKey("state"))
        type = container.lossyString(AnyCodingKey("type"))
    }
}

extension PVE {
    /// Every entry of the cluster's resources; only the networks are decoded with a kind.
    public static func sdnNodeNetworks() -> APIRequest<[SDNNodeNetwork]> {
        APIRequest(.get, "/cluster/resources")
    }

    public static func sdnZoneContent(node: String, zone: String) -> APIRequest<[SDNZoneContentEntry]> {
        APIRequest(.get, "/nodes/\(node)/sdn/zones/\(escapePath(zone))/content")
    }

    /// Bridges of a zone; `localnetwork` gives the node's own bridges.
    public static func sdnZoneBridges(node: String, zone: String) -> APIRequest<[SDNBridge]> {
        APIRequest(.get, "/nodes/\(node)/sdn/zones/\(escapePath(zone))/bridges")
    }

    public static func sdnIPVRF(node: String, zone: String) -> APIRequest<[SDNIPVRFRoute]> {
        APIRequest(.get, "/nodes/\(node)/sdn/zones/\(escapePath(zone))/ip-vrf")
    }

    public static func sdnMACVRF(node: String, vnet: String) -> APIRequest<[SDNMACVRFEntry]> {
        APIRequest(.get, "/nodes/\(node)/sdn/vnets/\(escapePath(vnet))/mac-vrf")
    }

    public static func sdnFabricRoutes(node: String, fabric: String) -> APIRequest<[SDNFabricRoute]> {
        APIRequest(.get, "/nodes/\(node)/sdn/fabrics/\(escapePath(fabric))/routes")
    }

    public static func sdnFabricNeighbors(node: String, fabric: String) -> APIRequest<[SDNFabricNeighbor]> {
        APIRequest(.get, "/nodes/\(node)/sdn/fabrics/\(escapePath(fabric))/neighbors")
    }

    public static func sdnFabricInterfaces(node: String, fabric: String) -> APIRequest<[SDNFabricInterfaceStatus]> {
        APIRequest(.get, "/nodes/\(node)/sdn/fabrics/\(escapePath(fabric))/interfaces")
    }
}
