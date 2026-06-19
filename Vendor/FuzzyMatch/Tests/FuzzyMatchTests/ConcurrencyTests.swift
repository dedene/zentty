// ===----------------------------------------------------------------------===//
//
// This source file is part of the FuzzyMatch open source project
//
// Copyright (c) 2026 Ordo One, AB. and the FuzzyMatch project authors
// Licensed under Apache License v2.0
//
// See LICENSE for license information
//
// SPDX-License-Identifier: Apache-2.0
//
// ===----------------------------------------------------------------------===//

import Testing

@testable import FuzzyMatch

// MARK: - Concurrent matching tests

/// Validates that parallel matching produces identical results to sequential matching.
/// Each task creates its own `ScoringBuffer` (the documented thread-safe pattern).

private let candidates: [String] = [
    "Apple Inc.", "Alphabet Inc.", "Amazon.com Inc.", "Advanced Micro Devices",
    "American Express Company", "AT&T Inc.", "Abbott Laboratories",
    "AbbVie Inc.", "Adobe Inc.", "Airbnb Inc.", "Alaska Air Group",
    "Align Technology", "Allegion plc", "Allstate Corporation",
    "Alnylam Pharmaceuticals", "Amgen Inc.", "Amphenol Corporation",
    "Analog Devices", "ANSYS Inc.", "Aon plc",
    "Applied Materials", "Aptiv PLC", "Archer-Daniels-Midland",
    "Arista Networks", "Arthur J. Gallagher", "Assurant Inc.",
    "Atmos Energy", "Autodesk Inc.", "Automatic Data Processing",
    "AutoZone Inc.", "Avalonbay Communities", "Avery Dennison",
    "Baker Hughes Company", "Ball Corporation", "Bank of America",
    "Bank of New York Mellon", "Baxter International", "Becton Dickinson",
    "Berkshire Hathaway", "Best Buy Co.", "Bio-Rad Laboratories",
    "Bio-Techne Corporation", "BlackRock Inc.", "Boeing Company",
    "Booking Holdings", "BorgWarner Inc.", "Boston Scientific",
    "Bristol-Myers Squibb", "Broadcom Inc.", "Broadridge Financial",
    "Brown & Brown Inc.", "Brown-Forman Corporation", "Builders FirstSource",
    "Cadence Design Systems", "Camden Property Trust", "Campbell Soup",
    "Capital One Financial", "Cardinal Health", "CarMax Inc.",
    "Carnival Corporation", "Carrier Global", "Catalent Inc.",
    "Caterpillar Inc.", "Cboe Global Markets", "CDW Corporation",
    "Celanese Corporation", "Centene Corporation", "CenterPoint Energy",
    "Ceridian HCM Holding", "CF Industries Holdings", "Charles River Laboratories",
    "Charles Schwab Corporation", "Charter Communications", "Chevron Corporation",
    "Chipotle Mexican Grill", "Church & Dwight", "Cigna Group",
    "Cincinnati Financial", "Cintas Corporation", "Cisco Systems",
    "Citigroup Inc.", "Citizens Financial Group", "Clorox Company",
    "CME Group Inc.", "CMS Energy Corporation", "Coca-Cola Company",
    "Cognizant Technology Solutions", "Colgate-Palmolive", "Comcast Corporation",
    "Comerica Incorporated", "ConocoPhillips", "Consolidated Edison",
    "Constellation Brands", "Constellation Energy", "CooperCompanies",
    "Copart Inc.", "Corning Incorporated", "Corteva Inc.",
    "CoStar Group Inc.", "Costco Wholesale", "Coterra Energy",
    "Crown Castle International", "CSX Corporation", "Cummins Inc.",
    "CVS Health Corporation", "Danaher Corporation", "Darden Restaurants",
    "DaVita Inc.", "Deere & Company", "Delta Air Lines",
    "Dentsply Sirona", "Devon Energy", "Dexcom Inc.",
    "Diamondback Energy", "Digital Realty Trust", "Discover Financial Services",
    "Discovery Inc.", "Dish Network Corporation", "Dollar General",
    "Dollar Tree Inc.", "Dominion Energy", "Dover Corporation",
    "Dow Inc.", "DTE Energy Company", "Duke Energy Corporation",
    "DuPont de Nemours", "Eastman Chemical", "Eaton Corporation",
    "eBay Inc.", "Ecolab Inc.", "Edison International",
    "Edwards Lifesciences", "Electronic Arts", "Elevance Health",
    "Eli Lilly and Company", "Emerson Electric", "Enphase Energy",
    "Entergy Corporation", "EOG Resources", "EPAM Systems",
    "EQT Corporation", "Equifax Inc.", "Equinix Inc.",
    "Essex Property Trust", "Estee Lauder Companies", "Etsy Inc.",
    "Everest Re Group", "Evergy Inc.", "Eversource Energy",
    "Exelon Corporation", "Expeditors International", "Extra Space Storage",
    "ExxonMobil Corporation", "F5 Inc.", "FactSet Research Systems",
    "Fair Isaac Corporation", "Fastenal Company", "Federal Realty Investment",
    "FedEx Corporation", "Fidelity National Information", "Fifth Third Bancorp",
    "First Republic Bank", "First Solar Inc.", "FirstEnergy Corporation",
    "Fiserv Inc.", "FleetCor Technologies", "FMC Corporation",
    "Ford Motor Company", "Fortinet Inc.", "Fortive Corporation",
    "Fox Corporation", "Franklin Templeton", "Freeport-McMoRan",
    "Garmin Ltd.", "Gartner Inc.", "GE HealthCare Technologies",
    "General Dynamics", "General Electric", "General Mills",
    "General Motors Company", "Generac Holdings", "Genuine Parts Company",
    "Gilead Sciences", "Global Payments", "Globe Life Inc.",
    "Goldman Sachs Group", "Halliburton Company", "Hartford Financial Services",
    "Hasbro Inc.", "HCA Healthcare", "Henry Schein Inc.",
    "Hershey Company", "Hess Corporation", "Hewlett Packard Enterprise",
    "Hilton Worldwide Holdings", "Hologic Inc.", "Home Depot",
    "Honeywell International", "Hormel Foods Corporation", "Host Hotels & Resorts",
    "Howmet Aerospace", "HP Inc.", "Hubbell Incorporated",
    "Humana Inc.", "Huntington Bancshares", "Huntington Ingalls Industries",
    "IDEXX Laboratories", "Illinois Tool Works", "Illumina Inc.",
    "Incyte Corporation", "Ingersoll Rand", "Insulet Corporation",
    "Intel Corporation", "Intercontinental Exchange", "International Business Machines",
    "International Flavors & Fragrances", "International Paper", "Interpublic Group",
    "Intuit Inc.", "Intuitive Surgical", "Invesco Ltd.",
    "IQVIA Holdings", "Iron Mountain", "J.B. Hunt Transport Services",
    "Jack Henry & Associates", "Jacobs Engineering", "Jazz Pharmaceuticals",
    "Johnson & Johnson", "Johnson Controls International", "JPMorgan Chase"
]

@Test func concurrentEditDistanceMatchingIsConsistent() async {
    let matcher = FuzzyMatcher()
    let query = matcher.prepare("apple")

    // Sequential baseline
    var seqBuffer = matcher.makeBuffer()
    var sequentialResults: [(String, Double)] = []
    for candidate in candidates {
        if let match = matcher.score(candidate, against: query, buffer: &seqBuffer) {
            sequentialResults.append((candidate, match.score))
        }
    }

    // Parallel: split into chunks and process with TaskGroup
    let chunkSize = 50
    let chunks = stride(from: 0, to: candidates.count, by: chunkSize).map { start in
        Array(candidates[start..<min(start + chunkSize, candidates.count)])
    }

    let parallelResults = await withTaskGroup(
        of: (Int, [(String, Double)]).self,
        returning: [(String, Double)].self
    ) { group in
        for (index, chunk) in chunks.enumerated() {
            group.addTask {
                var buffer = matcher.makeBuffer()
                var results: [(String, Double)] = []
                for candidate in chunk {
                    if let match = matcher.score(candidate, against: query, buffer: &buffer) {
                        results.append((candidate, match.score))
                    }
                }
                return (index, results)
            }
        }

        var collected: [(Int, [(String, Double)])] = []
        for await result in group {
            collected.append(result)
        }
        // Reassemble in chunk order
        return collected.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    #expect(parallelResults.count == sequentialResults.count)
    for (seq, par) in zip(sequentialResults, parallelResults) {
        #expect(seq.0 == par.0)
        #expect(seq.1 == par.1)
    }
}

@Test func concurrentSmithWatermanMatchingIsConsistent() async {
    let matcher = FuzzyMatcher(config: .smithWaterman)
    let query = matcher.prepare("bristol myers")

    // Sequential baseline
    var seqBuffer = matcher.makeBuffer()
    var sequentialResults: [(String, Double)] = []
    for candidate in candidates {
        if let match = matcher.score(candidate, against: query, buffer: &seqBuffer) {
            sequentialResults.append((candidate, match.score))
        }
    }

    // Parallel
    let chunkSize = 50
    let chunks = stride(from: 0, to: candidates.count, by: chunkSize).map { start in
        Array(candidates[start..<min(start + chunkSize, candidates.count)])
    }

    let parallelResults = await withTaskGroup(
        of: (Int, [(String, Double)]).self,
        returning: [(String, Double)].self
    ) { group in
        for (index, chunk) in chunks.enumerated() {
            group.addTask {
                var buffer = matcher.makeBuffer()
                var results: [(String, Double)] = []
                for candidate in chunk {
                    if let match = matcher.score(candidate, against: query, buffer: &buffer) {
                        results.append((candidate, match.score))
                    }
                }
                return (index, results)
            }
        }

        var collected: [(Int, [(String, Double)])] = []
        for await result in group {
            collected.append(result)
        }
        return collected.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    #expect(parallelResults.count == sequentialResults.count)
    for (seq, par) in zip(sequentialResults, parallelResults) {
        #expect(seq.0 == par.0)
        #expect(seq.1 == par.1)
    }
}

@Test func concurrentMixedModeMatchingIsConsistent() async {
    // Both modes processing the same data concurrently
    let edMatcher = FuzzyMatcher()
    let swMatcher = FuzzyMatcher(config: .smithWaterman)
    let edQuery = edMatcher.prepare("international")
    let swQuery = swMatcher.prepare("international")

    // Run both modes in parallel
    async let edResults: [(String, Double)] = {
        await withTaskGroup(
            of: [(String, Double)].self,
            returning: [(String, Double)].self
        ) { group in
            group.addTask {
                var buffer = edMatcher.makeBuffer()
                var results: [(String, Double)] = []
                for candidate in candidates {
                    if let match = edMatcher.score(
                        candidate, against: edQuery, buffer: &buffer) {
                        results.append((candidate, match.score))
                    }
                }
                return results
            }
            var all: [(String, Double)] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }()

    async let swResults: [(String, Double)] = {
        await withTaskGroup(
            of: [(String, Double)].self,
            returning: [(String, Double)].self
        ) { group in
            group.addTask {
                var buffer = swMatcher.makeBuffer()
                var results: [(String, Double)] = []
                for candidate in candidates {
                    if let match = swMatcher.score(
                        candidate, against: swQuery, buffer: &buffer) {
                        results.append((candidate, match.score))
                    }
                }
                return results
            }
            var all: [(String, Double)] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
    }()

    let ed = await edResults
    let sw = await swResults

    // Both should find matches (we don't compare across modes, just verify determinism)
    #expect(!ed.isEmpty)
    #expect(!sw.isEmpty)

    // Verify sequential produces the same as concurrent
    var seqEdBuffer = edMatcher.makeBuffer()
    var seqEdResults: [(String, Double)] = []
    for candidate in candidates {
        if let match = edMatcher.score(candidate, against: edQuery, buffer: &seqEdBuffer) {
            seqEdResults.append((candidate, match.score))
        }
    }
    #expect(ed.count == seqEdResults.count)
    for (seq, par) in zip(seqEdResults, ed) {
        #expect(seq.0 == par.0)
        #expect(seq.1 == par.1)
    }

    var seqSwBuffer = swMatcher.makeBuffer()
    var seqSwResults: [(String, Double)] = []
    for candidate in candidates {
        if let match = swMatcher.score(candidate, against: swQuery, buffer: &seqSwBuffer) {
            seqSwResults.append((candidate, match.score))
        }
    }
    #expect(sw.count == seqSwResults.count)
    for (seq, par) in zip(seqSwResults, sw) {
        #expect(seq.0 == par.0)
        #expect(seq.1 == par.1)
    }
}
