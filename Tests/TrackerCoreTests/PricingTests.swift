// Ported from tests/test_pricing.py, test for test.

import Foundation
import Testing
@testable import TrackerCore

private typealias Price = Pricing.Price

/// pytest.approx's default: within a relative 1e-6.
private func approx(_ value: Double, _ expected: Double) -> Bool {
    abs(value - expected) <= Swift.max(1e-6 * abs(expected), 1e-12)
}

@Test func longestPrefixWins() {
    #expect(Pricing.priceFor("claude-opus-5-5") == Price(4.00, 20.00, 0.20))
    #expect(Pricing.priceFor("claude-opus-5") == Price(5.00, 25.00, 0.50))
    #expect(Pricing.priceFor("claude-haiku-4-5-20251001") == Price(1.00, 5.00, 0.10))
}

@Test func unknownModelHasNoPrice() {
    #expect(Pricing.priceFor("<synthetic>") == nil)
    #expect(Pricing.priceFor("claude-opus-55") == nil)
}

@Test func estimateCostAllCategories() {
    let models: UsageStats.Models = [
        "claude-opus-5-5": [
            "input": 1_000_000,
            "output": 1_000_000,
            "cache_write_5m": 1_000_000,
            "cache_write_1h": 1_000_000,
            "cache_read": 1_000_000,
        ],
    ]
    let (dollars, unpriced) = Pricing.estimateCost(models)
    // 4 + 20 + 4*1.25 + 4*2 + 0.20
    #expect(approx(dollars, 37.20))
    #expect(unpriced == 0)
}

@Test func estimateCostReportsUnpricedTokens() {
    let (dollars, unpriced) = Pricing.estimateCost(["mystery": ["input": 7]])
    #expect(dollars == 0)
    #expect(unpriced == 7)
}

@Test func formatDollars() {
    #expect(Pricing.formatDollars(3.456) == "$3.46")
    #expect(Pricing.formatDollars(12345.6) == "$12,346")
}

@Test func estimateCostUsesRecordedCost() {
    let models: UsageStats.Models = [
        "gemini-4-argon": ["input": 1_000_000],
        "mystery": ["input": 5],
        "claude-opus-5-5": ["input": 1_000_000],
    ]

    let (dollars, unpriced) = Pricing.estimateCost(models, recorded: ["gemini-4-argon": 0.75])

    #expect(approx(dollars, 4.75))
    #expect(unpriced == 5)
}
