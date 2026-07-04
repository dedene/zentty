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

#if canImport(Foundation)
import Foundation

extension FuzzyMatcher {
    /// Returns an `AttributedString` with matched character ranges styled by the caller's closure.
    ///
    /// This is a convenience wrapper around ``highlight(_:against:)-1buqi`` that eliminates the
    /// boilerplate of converting `[Range<String.Index>]` to styled `AttributedString` ranges.
    /// Returns `nil` if the candidate doesn't match the query.
    ///
    /// The `applying` closure receives an `inout AttributeContainer` — set any attributes
    /// your platform supports. On Apple platforms with SwiftUI imported, this includes
    /// `.foregroundColor`, `.font`, etc. On Linux, Foundation-level attributes like
    /// `.inlinePresentationIntent` are available.
    ///
    /// ## Examples
    ///
    /// Foundation (cross-platform):
    /// ```swift
    /// let matcher = FuzzyMatcher()
    /// let query = matcher.prepare("mod")
    ///
    /// if let text = matcher.attributedHighlight("format:modern", against: query) {
    ///     $0.inlinePresentationIntent = .stronglyEmphasized
    /// } {
    ///     // text has "mod" in bold
    /// }
    /// ```
    ///
    /// SwiftUI (Apple platforms):
    /// ```swift
    /// #if canImport(SwiftUI)
    /// import SwiftUI
    ///
    /// if let text = matcher.attributedHighlight("format:modern", against: query) {
    ///     $0.foregroundColor = .orange
    ///     $0.font = .body.bold()
    /// } {
    ///     // text has "mod" in orange bold
    /// }
    /// #endif
    /// ```
    ///
    /// - Parameters:
    ///   - candidate: The candidate string to highlight.
    ///   - query: A prepared query from ``prepare(_:)``.
    ///   - style: A closure that configures the attributes applied to matched ranges.
    /// - Returns: A styled `AttributedString`, or `nil` if the candidate doesn't match.
    public func attributedHighlight(
        _ candidate: String,
        against query: FuzzyQuery,
        applying style: (inout AttributeContainer) -> Void
    ) -> AttributedString? {
        guard let ranges = highlight(candidate, against: query) else {
            return nil
        }

        var result = AttributedString(candidate)
        var container = AttributeContainer()
        style(&container)

        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else {
                continue
            }
            result[lower..<upper].mergeAttributes(container)
        }

        return result
    }

    /// Convenience overload accepting a raw query string.
    ///
    /// - Parameters:
    ///   - candidate: The candidate string to highlight.
    ///   - query: The query string to match against.
    ///   - style: A closure that configures the attributes applied to matched ranges.
    /// - Returns: A styled `AttributedString`, or `nil` if the candidate doesn't match.
    public func attributedHighlight(
        _ candidate: String,
        against query: String,
        applying style: (inout AttributeContainer) -> Void
    ) -> AttributedString? {
        attributedHighlight(candidate, against: prepare(query), applying: style)
    }
}
#endif
