//
//  TileServer.swift
//  Go Map!!
//
//  Created by Bryce Cogswell on 6/16/21.
//  Copyright © 2021 Bryce Cogswell. All rights reserved.
//

import CommonCrypto
import UIKit

private let BING_MAPS_KEY: String = [
	"ApunJH62",
	"__wQs1qE32KV",
	"rf6Fmncn",
	"7OZj6gWg_wtr27",
	"DQLDCkwkx",
	"Gl4RsItKW4Fkk"
].reduce("", { r, x in r + x })

private let BING_IDENTIFIER = "BingIdentifier"
private let MAPNIK_IDENTIFIER = "MapnikIdentifier"
private let OSM_GPS_TRACE_IDENTIFIER = "OsmGpsTraceIdentifier"
private let MAPBOX_LOCATOR_IDENTIFIER = "MapboxLocatorIdentifier"
private let NO_NAME_IDENTIFIER = "No Name Identifier"
private let MAXAR_PREMIUM_IDENTIFIER = "Maxar-Premium"
private let MAXAR_STANDARD_IDENTIFIER = "Maxar-Standard"

/// A provider of tile imagery, such as Bing or Mapbox
final class TileServer: Equatable, Codable {
	private static let iconCache: PersistentWebCache<UIImage> = {
		let cache = PersistentWebCache<UIImage>(name: "AerialServiceIconCache", memorySize: 10000)
		cache.removeObjectsAsyncOlderThan(Date(timeIntervalSinceNow: -30.0 * (24.0 * 60.0 * 60.0)))
		return cache
	}()

	static let defaultServer = BING_IDENTIFIER

	let name: String
	let identifier: String
	let url: String
	let best: Bool
	let apiKey: String
	let maxZoom: Int
	let roundZoomUp: Bool
	let startDate: String?
	let endDate: String?
	let wmsProjection: String
	let geoJSON: GeoJSON?
	let attributionString: String
	let attributionUrl: String
	let placeholderImage: Data?

	private let polygon: CGPath?

	enum CodingKeys: String, CodingKey {
		case name
		case identifier
		case url
		case best
		case apiKey
		case maxZoom
		case roundZoomUp
		case startDate
		case endDate
		case wmsProjection
		case geoJSON
		case attributionString
		case attributionUrl
	}

	private(set) var attributionIcon: UIImage?

	static let supportedProjections = [
		"EPSG:3857", // Google Maps and OpenStreetMap
		"EPSG:4326", // like 3857 but lat/lon in reverse order (sometimes)
		"EPSG:900913", // alias for 3857
		"EPSG:3587", // added as typo of 3785
		"EPSG:54004",
		"EPSG:41001",
		"EPSG:102113", // alias for 3857
		"EPSG:102100", // alias for 3857
		"EPSG:3785" // alias for 3857
	]

	convenience init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		let name = try container.decode(String.self, forKey: .name)
		let identifier = try container.decode(String.self, forKey: .identifier)
		let url = try container.decode(String.self, forKey: .url)
		let best = try container.decode(Bool.self, forKey: .best)
		let apiKey = try container.decode(String.self, forKey: .apiKey)
		let maxZoom = try container.decode(Int.self, forKey: .maxZoom)
		let roundZoomUp = try container.decode(Bool.self, forKey: .roundZoomUp)
		let startDate = try container.decode(String?.self, forKey: .startDate)
		let endDate = try container.decode(String?.self, forKey: .endDate)
		let wmsProjection = try container.decode(String.self, forKey: .wmsProjection)
		let geoJSON = try container.decode(GeoJSON?.self, forKey: .geoJSON)
		let attributionString = try container.decode(String.self, forKey: .attributionString)
		let attributionUrl = try container.decode(String.self, forKey: .attributionUrl)

		self.init(withName: name, identifier: identifier, url: url, best: best,
		          apiKey: apiKey, maxZoom: maxZoom, roundUp: roundZoomUp, startDate: startDate, endDate: endDate,
		          wmsProjection: wmsProjection, geoJSON: geoJSON,
		          attribString: attributionString, attribIcon: nil, attribUrl: attributionUrl)
	}

	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(name, forKey: .name)
		try container.encode(identifier, forKey: .identifier)
		try container.encode(url, forKey: .url)
		try container.encode(best, forKey: .best)
		try container.encode(apiKey, forKey: .apiKey)
		try container.encode(maxZoom, forKey: .maxZoom)
		try container.encode(roundZoomUp, forKey: .roundZoomUp)
		try container.encode(startDate, forKey: .startDate)
		try container.encode(endDate, forKey: .endDate)
		try container.encode(wmsProjection, forKey: .wmsProjection)
		try container.encode(geoJSON, forKey: .geoJSON)
		try container.encode(attributionString, forKey: .attributionString)
		try container.encode(attributionUrl, forKey: .attributionUrl)
	}

	init(
		withName name: String,
		identifier: String,
		url: String,
		best: Bool,
		apiKey: String,
		maxZoom: Int,
		roundUp: Bool,
		startDate: String?,
		endDate: String?,
		wmsProjection projection: String?,
		geoJSON: GeoJSON?,
		attribString: String,
		attribIcon: UIImage?,
		attribUrl: String)
	{
		// normalize URLs
		var url = url
		url = url.replacingOccurrences(of: "{ty}", with: "{-y}")
		url = url.replacingOccurrences(of: "{zoom}", with: "{z}")

		self.name = name
		self.identifier = identifier
		self.url = url
		self.best = best
		self.apiKey = apiKey
		wmsProjection = projection ?? ""
		attributionString = attribString.count != 0 ? attribString : name
		attributionUrl = attribUrl

		self.maxZoom = maxZoom > 0 ? maxZoom : 21
		roundZoomUp = roundUp
		self.startDate = startDate
		self.endDate = endDate
		self.geoJSON = geoJSON
		polygon = geoJSON?.cgPath.copy()
		attributionIcon = attribIcon

		placeholderImage = TileServer.getPlaceholderImage(forIdentifier: identifier)
	}

	static func ==(lhs: TileServer, rhs: TileServer) -> Bool {
		return lhs.identifier == rhs.identifier
	}

	func isBingAerial() -> Bool {
		return identifier == BING_IDENTIFIER
	}

	func isMapnik() -> Bool {
		return identifier == MAPNIK_IDENTIFIER
	}

	func isOsmGpxOverlay() -> Bool {
		return identifier == OSM_GPS_TRACE_IDENTIFIER
	}

	func isMaxar() -> Bool {
		return (identifier == MAXAR_PREMIUM_IDENTIFIER) || (identifier == MAXAR_STANDARD_IDENTIFIER)
	}

	func coversLocation(_ point: LatLon) -> Bool {
		guard let polygon = polygon else { return true }
		return polygon.contains(CGPoint(OSMPoint(point)), using: .winding)
	}

	func isGlobalImagery() -> Bool {
		return polygon == nil
	}

	static var dateFormatterList: [DateFormatter] = {
		let formatterYYYYMMDD = DateFormatter()
		formatterYYYYMMDD.dateFormat = "yyyy-MM-dd"
		formatterYYYYMMDD.timeZone = NSTimeZone(forSecondsFromGMT: 0) as TimeZone

		let formatterYYYYMM = DateFormatter()
		formatterYYYYMM.dateFormat = "yyyy-MM"
		formatterYYYYMM.timeZone = NSTimeZone(forSecondsFromGMT: 0) as TimeZone

		let formatterYYYY = DateFormatter()
		formatterYYYY.dateFormat = "yyyy"
		formatterYYYY.timeZone = NSTimeZone(forSecondsFromGMT: 0) as TimeZone

		return [
			formatterYYYYMMDD,
			formatterYYYYMM,
			formatterYYYY
		]
	}()

	class func date(from string: String?) -> Date? {
		guard let string = string else {
			return nil
		}
		for formatter in dateFormatterList {
			let date = formatter.date(from: string)
			if let date = date {
				return date
			}
		}
		return nil
	}

	static let none = TileServer(
		withName: "<none>",
		identifier: "",
		url: "",
		best: false,
		apiKey: "",
		maxZoom: 0,
		roundUp: false,
		startDate: nil,
		endDate: nil,
		wmsProjection: nil,
		geoJSON: nil,
		attribString: "",
		attribIcon: nil,
		attribUrl: "")

	static let maxarPremiumAerial: TileServer = {
		let service = TileServer(
			withName: "Maxar Premium Aerial",
			identifier: MAXAR_PREMIUM_IDENTIFIER,
			url: MaxarPremiumUrl,
			best: false,
			apiKey: "",
			maxZoom: 21,
			roundUp: true,
			startDate: nil,
			endDate: nil,
			wmsProjection: nil,
			geoJSON: nil,
			attribString: "Maxar Premium",
			attribIcon: nil,
			attribUrl: "https://wiki.openstreetmap.org/wiki/DigitalGlobe")
		service.loadIcon(fromWeb: "https://osmlab.github.io/editor-layer-index/sources/world/Maxar.png")
		return service
	}()

	static let mapnik = TileServer(
		withName: "MapnikTiles",
		identifier: MAPNIK_IDENTIFIER,
		url: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
		best: false,
		apiKey: "",
		maxZoom: 19,
		roundUp: false,
		startDate: nil,
		endDate: nil,
		wmsProjection: nil,
		geoJSON: nil,
		attribString: "",
		attribIcon: nil,
		attribUrl: "")

	static let gpsTrace = TileServer(
		withName: "OSM GPS Traces",
		identifier: OSM_GPS_TRACE_IDENTIFIER,
		url: "https://gps.tile.openstreetmap.org/lines/{z}/{x}/{y}.png",
		best: false,
		apiKey: "",
		maxZoom: 20,
		roundUp: false,
		startDate: nil,
		endDate: nil,
		wmsProjection: nil,
		geoJSON: nil,
		attribString: "",
		attribIcon: nil,
		attribUrl: "")

	static let mapboxLocator = TileServer(
		withName: "Mapbox Locator",
		identifier: MAPBOX_LOCATOR_IDENTIFIER,
		url: "https://api.mapbox.com/styles/v1/openstreetmap/ckasmteyi1tda1ipfis6wqhuq/tiles/256/{zoom}/{x}/{y}{@2x}?access_token={apikey}",
		best: false,
		apiKey: MapboxLocatorToken,
		maxZoom: 20,
		roundUp: false,
		startDate: nil,
		endDate: nil,
		wmsProjection: nil,
		geoJSON: nil,
		attribString: "",
		attribIcon: nil,
		attribUrl: "")

	static let noName = TileServer(
		withName: "QA Poole No Name",
		identifier: NO_NAME_IDENTIFIER,
		url: "https://tile{switch:2,3}.poole.ch/noname/{zoom}/{x}/{y}.png",
		best: false,
		apiKey: "",
		maxZoom: 25,
		roundUp: false,
		startDate: nil,
		endDate: nil,
		wmsProjection: nil,
		geoJSON: nil,
		attribString: "",
		attribIcon: nil,
		attribUrl: "")

	private static let builtinBingAerial = TileServer(
		withName: "Bing Aerial",
		identifier: BING_IDENTIFIER,
		url: "https://ecn.{switch:t0,t1,t2,t3}.tiles.virtualearth.net/tiles/a{u}.jpeg?g=10618&key={apikey}",
		best: false,
		apiKey: BING_MAPS_KEY,
		maxZoom: 21,
		roundUp: true,
		startDate: nil,
		endDate: nil,
		wmsProjection: nil,
		geoJSON: nil,
		attribString: "",
		attribIcon: UIImage(named: "bing-logo-white"),
		attribUrl: "")

	private static var dynamicBingAerial: TileServer?

	static var bingAerial: TileServer {
		return Self.dynamicBingAerial ?? builtinBingAerial
	}

	static func fetchDynamicBingServer(_ callback: ((Result<TileServer, Error>) -> Void)?) {
		struct Welcome: Decodable {
			let brandLogoUri: String
			let resourceSets: [ResourceSet]
			let statusCode: Int
		}
		struct ResourceSet: Decodable {
			let resources: [Resource]
		}
		struct Resource: Decodable {
			let __type: String
			let imageUrl: String
			let imageUrlSubdomains: [String]
			let zoomMax, zoomMin: Int
		}
		let url = "https://dev.virtualearth.net/REST/v1/Imagery/Metadata/Aerial?include=ImageryProviders&key=" +
			BING_MAPS_KEY
		guard let url = URL(string: url) else { return }
		URLSession.shared.data(with: url, completionHandler: { result in
			DispatchQueue.main.async(execute: {
				switch result {
				case let .success(data):
					do {
						let json = try JSONDecoder().decode(Welcome.self, from: data)
						guard
							json.statusCode == 200,
							let resource = json.resourceSets.first?.resources.first
						else {
							callback?(.failure(NSError()))
							return
						}

						let subdomains = resource.imageUrlSubdomains.joined(separator: ",")
						var imageUrl = resource.imageUrl
						imageUrl = imageUrl.replacingOccurrences(of: "http://",
						                                         with: "https://")
						imageUrl = imageUrl.replacingOccurrences(of: "{subdomain}",
						                                         with: "{switch:\(subdomains)}")
						imageUrl = imageUrl.replacingOccurrences(of: "{quadkey}",
						                                         with: "{u}")
						imageUrl += "&key={apikey}"
						let bing = TileServer(withName: Self.builtinBingAerial.name,
						                      identifier: Self.builtinBingAerial.identifier,
						                      url: imageUrl,
						                      best: false,
						                      apiKey: BING_MAPS_KEY,
						                      maxZoom: resource.zoomMax,
						                      roundUp: Self.builtinBingAerial.roundZoomUp,
						                      startDate: Self.builtinBingAerial.startDate,
						                      endDate: Self.builtinBingAerial.endDate,
						                      wmsProjection: Self.builtinBingAerial.wmsProjection,
						                      geoJSON: Self.builtinBingAerial.geoJSON,
						                      attribString: Self.builtinBingAerial.attributionString,
						                      attribIcon: Self.builtinBingAerial.attributionIcon,
						                      attribUrl: Self.builtinBingAerial.attributionUrl)
						bing.loadIcon(fromWeb: json.brandLogoUri)
						Self.dynamicBingAerial = bing
						callback?(.success(bing))
					} catch {
						print("\(error)")
						callback?(.failure(error))
					}
				case let .failure(error):
					callback?(.failure(error))
				}
			})
		})
	}

	func dictionary() -> [String: Any] {
		return [
			"name": name,
			"url": url,
			"zoom": NSNumber(value: maxZoom),
			"roundUp": NSNumber(value: roundZoomUp),
			"projection": wmsProjection
		]
	}

	convenience init(withDictionary dict: [String: Any]) {
		var url = dict["url"] as! String

		// convert a saved aerial that uses a subdomain list to the new format
		if let subdomains = dict["subdomains"] as? [String] {
			if subdomains.count > 0 {
				var s = subdomains.joined(separator: ",")
				s = String(format: "{switch:\(s)}")
				url = url.replacingOccurrences(of: "{t}", with: s)
			}
		}

		var projection = dict["projection"] as? String
		if (projection?.count ?? 0) == 0 {
			projection = nil
		}

		self.init(withName: dict["name"] as! String,
		          identifier: url,
		          url: url,
		          best: false,
		          apiKey: "",
		          maxZoom: (dict["zoom"] as? NSNumber)?.intValue ?? 0,
		          roundUp: (dict["roundUp"] as? NSNumber)?.boolValue ?? false,
		          startDate: nil, endDate: nil,
		          wmsProjection: projection,
		          geoJSON: nil,
		          attribString: "",
		          attribIcon: nil,
		          attribUrl: "")
	}

	var metadataUrl: String? {
		if isBingAerial() {
			return "https://dev.virtualearth.net/REST/V1/Imagery/Metadata/Aerial/%f,%f?zl=%d&include=ImageryProviders&key=" +
				BING_MAPS_KEY
		}
		return nil
	}

	private static func getPlaceholderImage(forIdentifier ident: String) -> Data? {
		let name: String
		switch ident {
		case BING_IDENTIFIER: name = "BingPlaceholderImage"
		case "EsriWorldImagery": name = "EsriPlaceholderImage"
		default: return nil
		}
		if let path = Bundle.main.path(forResource: name, ofType: "png") ??
			Bundle.main.path(forResource: name, ofType: "jpg"),
			let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
			data.count > 0
		{
			return data
		}
		return nil
	}

	func isPlaceholderImage(_ data: Data) -> Bool {
		return placeholderImage?.elementsEqual(data) ?? false
	}

	func scaleAttributionIcon(toHeight height: CGFloat) {
		if let attributionIcon = attributionIcon,
		   abs(attributionIcon.size.height - height) > 0.1
		{
			let scale = attributionIcon.size.height / height
			var size = attributionIcon.size
			size.height /= scale
			size.width /= scale
			UIGraphicsBeginImageContext(size)
			attributionIcon.draw(in: CGRect(x: 0.0, y: 0.0, width: size.width, height: size.height))
			let imageCopy = UIGraphicsGetImageFromCurrentImageContext()
			UIGraphicsEndImageContext()
			self.attributionIcon = imageCopy
		}
	}

	func loadIcon(fromWeb url: String) {
		DispatchQueue.main.async(execute: {
			// FIXME: cache requires requests to start on main thread. We should have the cache use its own queue
			self.attributionIcon = TileServer.iconCache.object(withKey: self.identifier,
			                                                   fallbackURL: { URL(string: url) },
			                                                   objectForData: { UIImage(data: $0) },
			                                                   completion: { self.attributionIcon = try? $0.get() })
		})
	}

	var description: String {
		return name
	}

	private static func TileToWMSCoords(_ tx: Int, _ ty: Int, _ z: Int, _ projection: String) -> OSMPoint {
		let zoomSize = Double(1 << z)
		let lon = Double(tx) / zoomSize * .pi * 2 - .pi
		let lat = atan(sinh(.pi * (1 - Double(2 * ty) / zoomSize)))
		var loc: OSMPoint
		if projection == "EPSG:4326" {
			loc = OSMPoint(x: lon * 180 / .pi, y: lat * 180 / .pi)
		} else {
			// EPSG:3857 and others
			loc = OSMPoint(x: lon, y: log(tan((.pi / 2 + lat) / 2))) // mercatorRaw
			loc = Mult(loc, 20_037508.34 / .pi)
		}
		return loc
	}

	func url(forZoom zoom: Int, tileX: Int, tileY: Int) -> URL {
		var url = self.url

		// handle switch in URL
		if let begin = url.range(of: "{switch:"),
		   let end = url[begin.upperBound...].range(of: "}")
		{
			let list = url[begin.upperBound..<end.lowerBound].components(separatedBy: ",")
			if list.count > 0 {
				let t = list[(tileX + tileY) % list.count]
				url.replaceSubrange(begin.lowerBound..<end.upperBound, with: t)
			}
		}

		if !wmsProjection.isEmpty {
			// WMS
			let minXmaxY = Self.TileToWMSCoords(tileX, tileY, zoom, wmsProjection)
			let maxXminY = Self.TileToWMSCoords(tileX + 1, tileY + 1, zoom, wmsProjection)
			let bbox: String
			if wmsProjection == "EPSG:4326", url.lowercased().contains("crs={proj}") {
				// reverse lat/lon for EPSG:4326 when WMS version is 1.3 (WMS 1.1 uses srs=epsg:4326 instead
				bbox = "\(maxXminY.y),\(minXmaxY.x),\(minXmaxY.y),\(maxXminY.x)" // lat,lon
			} else {
				bbox = "\(minXmaxY.x),\(maxXminY.y),\(maxXminY.x),\(minXmaxY.y)" // lon,lat
			}

			url = url.replacingOccurrences(of: "{width}", with: "256")
			url = url.replacingOccurrences(of: "{height}", with: "256")
			url = url.replacingOccurrences(of: "{proj}", with: wmsProjection)
			url = url.replacingOccurrences(of: "{bbox}", with: bbox)
			url = url.replacingOccurrences(of: "{wkid}",
			                               with: wmsProjection.replacingOccurrences(of: "EPSG:", with: ""))
			url = url.replacingOccurrences(of: "{w}", with: "\(minXmaxY.x)")
			url = url.replacingOccurrences(of: "{s}", with: "\(maxXminY.y)")
			url = url.replacingOccurrences(of: "{n}", with: "\(maxXminY.x)")
			url = url.replacingOccurrences(of: "{e}", with: "\(minXmaxY.y)")
		} else {
			// TMS
			let u = TileToQuadKey(x: tileX, y: tileY, z: zoom)
			let x = "\(tileX)"
			let y = "\(tileY)"
			let negY = "\((1 << zoom) - tileY - 1)"
			let z = "\(zoom)"

			url = url.replacingOccurrences(of: "{u}", with: u)
			url = url.replacingOccurrences(of: "{x}", with: x)
			url = url.replacingOccurrences(of: "{y}", with: y)
			url = url.replacingOccurrences(of: "{-y}", with: negY)
			url = url.replacingOccurrences(of: "{z}", with: z)
		}
		// retina screen
		let retina = UIScreen.main.scale > 1 ? "@2x" : ""
		url = url.replacingOccurrences(of: "{@2x}", with: retina)

		// apikey
		url = url.replacingOccurrences(of: "{apikey}", with: apiKey)

		let urlString = url.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) ?? url
		// https://ecn.t1.tiles.virtualearth.net/tiles/a12313302102001233031.jpeg?g=587&key=ApunJH62__wQs1qE32KVrf6Fmncn7OZj6gWg_wtr27DQLDCkwkxGl4RsItKW4Fkk
		// https://ecn.%7Bswitch:t0,t1,t2,t3%7D.tiles.virtualearth.net/tiles/a%7Bu%7D.jpeg?g=587&key=ApunJH62__wQs1qE32KVrf6Fmncn7OZj6gWg_wtr27DQLDCkwkxGl4RsItKW4Fkk
		// https://ecn.{switch:t0,t1,t2,t3}.tiles.virtualearth.net/tiles/a{u}.jpeg?g=587&key=ApunJH62__wQs1qE32KVrf6Fmncn7OZj6gWg_wtr27DQLDCkwkxGl4RsItKW4Fkk

		return URL(string: urlString)!
	}
}
