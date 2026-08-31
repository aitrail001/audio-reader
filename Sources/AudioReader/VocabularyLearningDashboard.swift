import SwiftUI

struct VocabularyLearningDashboard: View {
    let snapshot: VocabularyLearningSnapshot
    let onStartSession: () -> Void

    private var metrics: [VocabularyLearningMetric] {
        [
            .init(id: "due", title: "Due", value: "\(snapshot.queue.due.count)", symbol: "clock"),
            .init(id: "new", title: "New", value: "\(snapshot.queue.new.count)", symbol: "sparkles"),
            .init(id: "learning", title: "Learning", value: "\(snapshot.queue.learning.count)", symbol: "brain.head.profile"),
            .init(id: "reviewedToday", title: "Reviewed today", value: "\(snapshot.todayReviewCount)", symbol: "checkmark.circle"),
            .init(id: "streak", title: "Streak", value: "\(snapshot.streakDays) d", symbol: "calendar"),
            .init(id: "retention", title: "30-day retention", value: retentionLabel, symbol: "scope")
        ]
    }

    private var retentionLabel: String {
        guard let retention = snapshot.retention else { return "—" }
        return retention.formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LearningDashboardHeader(
                session: snapshot.queue.sessionBreakdown,
                onStartSession: onStartSession
            )

            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                        VocabularyLearningMetricValue(metric: metric)
                        if index < metrics.count - 1 {
                            Divider()
                                .overlay(Palette.line)
                                .frame(height: 42)
                                .padding(.horizontal, 14)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Learning summary")

            if !snapshot.queue.session.isEmpty {
                VocabularyTodayCards(
                    entries: snapshot.queue.session,
                    dueCount: snapshot.queue.sessionBreakdown.dueCount
                )
            }

            if !snapshot.forecast.isEmpty {
                VocabularyDueForecastRow(forecast: snapshot.forecast)
            }

            if !snapshot.books.isEmpty {
                VocabularyBookDistributionRow(books: snapshot.books)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Palette.panel)
    }
}

private struct LearningDashboardHeader: View {
    let session: VocabularyStudySessionBreakdown
    let onStartSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
            startButton
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Today’s study")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier("words.learningDashboard")
            Text("Due cards come first, followed by up to \(VocabularyLearningPolicy.dailyNewCardLimit) new cards.")
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            if session.totalCount > 0 {
                Text(sessionSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.gold)
                    .accessibilityLabel(sessionAccessibilitySummary)
            }
        }
    }

    private var startButton: some View {
        Button(action: onStartSession) {
            Label(
                session.totalCount == 1 ? "Study 1 card today" : "Study \(session.totalCount) cards today",
                systemImage: "play.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.terracotta)
        .controlSize(.large)
        .disabled(session.totalCount == 0)
        .accessibilityIdentifier("words.studyToday")
        .accessibilityHint(
            session.totalCount == 0
                ? "There are no due or new cards."
                : "Starts \(sessionAccessibilitySummary)."
        )
    }

    private var sessionSummary: String {
        if session.dueCount == 0 { return "\(session.newCount) new" }
        if session.newCount == 0 { return "\(session.dueCount) due" }
        return "\(session.dueCount) due + \(session.newCount) new"
    }

    private var sessionAccessibilitySummary: String {
        let due = session.dueCount == 1 ? "1 due card" : "\(session.dueCount) due cards"
        let new = session.newCount == 1 ? "1 new card" : "\(session.newCount) new cards"
        if session.dueCount == 0 { return new }
        if session.newCount == 0 { return due }
        return "\(due) and \(new)"
    }
}

private struct VocabularyLearningMetric: Identifiable {
    let id: String
    let title: String
    let value: String
    let symbol: String
}

private struct VocabularyLearningMetricValue: View {
    let metric: VocabularyLearningMetric

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: metric.symbol)
                .foregroundStyle(Palette.gold)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
                Text(metric.value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Palette.ink)
            }
        }
        .frame(minWidth: 104, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title), \(metric.value)")
        .accessibilityIdentifier("words.metric.\(metric.id)")
    }
}

private struct VocabularyTodayCards: View {
    private static let previewLimit = 20

    let entries: [VocabularyStudyCard]
    let dueCount: Int

    private var preview: ArraySlice<VocabularyStudyCard> {
        entries.prefix(Self.previewLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today’s cards")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier("words.todayCards")
                Spacer()
                Text("\(entries.count) ready")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Palette.dim)
            }

            // The preview is capped at 20, so eagerly exposing every row keeps
            // the complete daily preview reachable to VoiceOver and UI tests.
            VStack(spacing: 0) {
                ForEach(Array(preview.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(index < dueCount ? "Due" : "New")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(index < dueCount ? Palette.terracotta : Palette.gold)
                            .frame(width: 38, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.word)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                            Text("\(entry.bookTitle) · \(entry.chapterTitle)")
                                .font(.caption)
                                .foregroundStyle(Palette.dim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(index < dueCount ? "Due" : "New") card, \(entry.word), \(entry.bookTitle), \(entry.chapterTitle)"
                    )
                    .accessibilityIdentifier("words.todayCard.\(entry.id)")

                    if entry.id != preview.last?.id {
                        Divider().overlay(Palette.line)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 12))

            if entries.count > preview.count {
                Text("The study session includes \(entries.count - preview.count) more cards after this preview.")
                    .font(.caption)
                    .foregroundStyle(Palette.dim)
            }
        }
    }
}

private struct VocabularyDueForecastRow: View {
    let forecast: [VocabularyDueForecast]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Due forecast")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(forecast) { bucket in
                        VStack(spacing: 5) {
                            Text(bucket.day, format: .dateTime.weekday(.abbreviated))
                                .font(.caption)
                                .foregroundStyle(Palette.dim)
                            Text("\(bucket.count)")
                                .font(.headline)
                                .foregroundStyle(Palette.ink)
                        }
                        .frame(minWidth: 58)
                        .padding(.vertical, 8)
                        .background(bucket.count > 0 ? Palette.goldSoft : Palette.panel2)
                        .clipShape(.rect(cornerRadius: 10))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(bucket.day.formatted(date: .complete, time: .omitted)), \(bucket.count) due"
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct VocabularyBookDistributionRow: View {
    let books: [VocabularyBookLearningDistribution]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By book")
                .font(.headline)
                .foregroundStyle(Palette.ink)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(books) { book in
                        VocabularyBookDistributionCard(book: book)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct VocabularyBookDistributionCard: View {
    let book: VocabularyBookLearningDistribution

    private var scheduledFraction: Double {
        guard book.totalCount > 0 else { return 0 }
        return Double(book.learningCount + book.reviewCount) / Double(book.totalCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(book.bookTitle, systemImage: "book.closed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            ProgressView(value: scheduledFraction)
                .tint(Palette.gold)
            Text("\(book.dueCount) due · \(book.newCount) new · \(book.learningCount) learning")
                .font(.caption)
                .foregroundStyle(Palette.dim)
            Text("\(book.reviewedToday) reviewed today")
                .font(.caption2)
                .foregroundStyle(Palette.dim)
        }
        .frame(minWidth: 220, maxWidth: 280, alignment: .leading)
        .padding(12)
        .background(Palette.panel2)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(book.bookTitle), \(book.totalCount) cards, \(book.dueCount) due, \(book.newCount) new, \(book.learningCount) learning, \(book.reviewedToday) reviewed today"
        )
    }
}
