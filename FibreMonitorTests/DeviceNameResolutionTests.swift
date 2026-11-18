import XCTest
@testable import FibreMonitor

final class DeviceNameResolutionTests: XCTestCase {
    func testNamePrioritySkipsGenericRouterLabelsAndUsesCachedBonjourName() {
        let device = makeDevice(mac: "00:03:93:11:22:33", hostname: "Unknown", alias: "*")

        XCTAssertEqual(
            DeviceNameResolver.name(for: device, userAlias: nil, discoveredName: "Living Room TV"),
            "Living Room TV"
        )
        XCTAssertEqual(
            DeviceNameResolver.name(for: device, userAlias: "  Ray's iPhone  ", discoveredName: "Living Room TV"),
            "Ray's iPhone"
        )
    }

    func testVendorAndPrivateAddressFallbacks() {
        let appleDevice = makeDevice(mac: "00:03:93:11:22:33", hostname: "", alias: "")
        XCTAssertEqual(DeviceNameResolver.name(for: appleDevice, userAlias: nil, discoveredName: nil), "Apple device")

        let privateDevice = makeDevice(mac: "1e:e0:11:39:c0:a4", hostname: "Unknown", alias: "")
        XCTAssertTrue(DeviceNameResolver.isLocallyAdministeredMAC(privateDevice.mac))
        XCTAssertEqual(DeviceNameResolver.name(for: privateDevice, userAlias: nil, discoveredName: nil), "Private Wi-Fi Device")
    }

    func testParserMergesUsefulFieldsAcrossRouterRecordsAndDHCPLease() {
        let routerText = #"""
        function USERDevice(Domain,IpAddr,MacAddr,Port,IpType,DevType,DevStatus,PortType,Time,HostName,VendorClassId,Alias,MACAddress,IPAddress,Name) { }
        function USERDeviceNew(Domain,IpAddr,MacAddr,Port,IpType,DevType,DevStatus,PortType,Time,HostName,IPv4Enabled,IPv6Enabled,DeviceType,UserDevAlias,UserSpecifiedDeviceType,LeaseTimeRemaining,RealMacAddr) { }
        var devices = new Array(
          new USERDevice("d1","192.168.100.20","AA:BB:CC:00:00:01","SSID1","DHCP","","Online","WIFI","0:10","Unknown","","*","","",""),
          new USERDeviceNew("d1","192.168.100.20","aa:bb:cc:00:00:01","SSID1","DHCP","","Online","WIFI","0:10","","1","1","0","","0","0",""),
          null);
        """#
        let dhcpText = #"""
        function DHCPInfo(domain,name,ip,mac,remaintime,devtype,interfacetype,AddressSource,ConnectedTime) { }
        var leases = new Array(new DHCPInfo("lease","Kwesi's iPhone","192.168.100.20","aa:bb:cc:00:00:01","300","Apple","802.11","DHCP","600"),null);
        """#

        let parsed = HuaweiOntClient.parseDevices(routerText)
        let enriched = HuaweiOntClient.enrichDevices(parsed, withDhcpInfo: dhcpText)

        XCTAssertEqual(enriched.count, 1)
        XCTAssertEqual(enriched[0].hostName, "Kwesi's iPhone")
        XCTAssertEqual(enriched[0].dhcpVendor, "Apple")
        XCTAssertEqual(enriched[0].ip, "192.168.100.20")
    }

    private func makeDevice(mac: String, hostname: String, alias: String) -> OntDevice {
        OntDevice(
            mac: mac,
            ip: "192.168.100.20",
            hostName: hostname,
            routerAlias: alias,
            dhcpVendor: "",
            port: .wifi24(ssidIndex: 1),
            isOnline: true,
            connectedTime: "0:01"
        )
    }
}
