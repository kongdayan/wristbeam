import Foundation

extension MetricDaySeries {
    /// Keep chronological endpoints and extrema in each screen column. Breaks and
    /// interval totals keep their original semantics. Cursor queries use the source.
    func sampled(width: Double, domain: ClosedRange<Date>) -> MetricDaySeries {
        guard width.isFinite, width > 0, domain.upperBound > domain.lowerBound else { return self }
        let columns = max(1, Int(min(4096, width)))
        guard points.count > columns * 4, !points.contains(where: { $0.end != nil }) else { return self }
        let duration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        var output: [MetricSeriesPoint] = [], bucket: [MetricSeriesPoint] = []
        var column: Int?, previous: MetricSeriesPoint?
        func flush() {
            guard let first = bucket.first, let last = bucket.last else { return }
            let minimum = bucket.min { ($0.value ?? 0) < ($1.value ?? 0) }!
            let maximum = bucket.max { ($0.value ?? 0) < ($1.value ?? 0) }!
            var seen = Set<Date>()
            output += [first, minimum, maximum, last].sorted { $0.timestamp < $1.timestamp }.filter { seen.insert($0.timestamp).inserted }
            bucket.removeAll(keepingCapacity: true)
        }
        for point in points {
            // Include edge neighbors so the line still intersects zoom boundaries.
            if point.timestamp < domain.lowerBound { previous = point; continue }
            if let before = previous, before.timestamp < domain.lowerBound { output.append(before); previous = nil }
            if point.timestamp > domain.upperBound { flush(); output.append(point); break }
            let nextColumn = Int(point.timestamp.timeIntervalSince(domain.lowerBound) / duration * Double(columns))
            if point.value == nil {
                flush(); output.append(point); previous = point; column = nil; continue
            }
            if let previous, point.timestamp.timeIntervalSince(previous.timestamp) > gapLimit || point.label != previous.label { flush(); column = nil }
            if let first = bucket.first, point.timestamp.timeIntervalSince(first.timestamp) > gapLimit / 2 { flush() }
            if nextColumn != column { flush(); column = nextColumn }
            bucket.append(point); previous = point
        }
        flush()
        var result = self; result.points = output
        return result
    }
}
