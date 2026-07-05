import Foundation

struct URLQueryParamRule: Sendable {
    let domain: String
    let stripParams: Set<String>
}

enum URLQueryParamRules {
    static let builtIn: [URLQueryParamRule] = [
        .init(domain: "youtube.com", stripParams: ["si", "feature", "pp", "ab_channel"]),
        .init(domain: "youtu.be", stripParams: ["si", "feature"]),
    ]

    private static let knownTrackingParams: Set<String> = [
        "fbclid",
        "gclid",
        "gclsrc",
        "dclid",
        "msclkid",
        "mc_cid",
        "mc_eid",
        "igshid",
        "icid",
        "yclid",
        "twclid",
        "ttclid",
        "s_kwcid",
        "sc_cid",
        "_hsenc",
        "_hsmi",
        "vero_id",
        "wickedid",
        "oly_anon_id",
        "oly_enc_id",
        "rb_clickid",
        "spm",
        "ref_src",
        "ref_url",
    ]

    static func rule(for host: String, in rules: [URLQueryParamRule]) -> URLQueryParamRule? {
        let normalizedHost = host.lowercased()
        return rules.first(where: {
            let domain = $0.domain.lowercased()
            return normalizedHost == domain || normalizedHost.hasSuffix(".\(domain)")
        })
    }

    static func isKnownTrackingParam(_ name: String) -> Bool {
        let normalizedName = name.lowercased()
        return normalizedName.hasPrefix("utm_") || knownTrackingParams.contains(normalizedName)
    }
}
