import SwiftUI

struct VocabularyLearningDashboard: View {
    let snapshot: VocabularyLearningSnapshot
    let onStartSession: () -> Void

    private var metrics: [VocabularyLearningMetric] {
        [
            .init(id: "due", title: "Due", value: "\(snapshot.queue.due.count)", symbol: "clock"),
            .init(id: "new", title: "New", value: "\(snapshot.queue.new.count)", symbol: "sparkles"),
            .init(id: "learning", title: "Learning", value: "\(snapshot.queue.learning.count)", symbol: "brain.head.profile"),
            .init(id: "today", title: "Today", value: "\(snapshot.todayReviewCount)", symbol: "checkmark.circle"),
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
                sessionCount: snapshot.queue.session.count,
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
        .accessibilityIdentifier("words.learningDashboard")
    }
}

private struct LearningDashboardHeader: View {
    let sessionCount: Int
    let onStartSession: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                title
                Spacer(minLength: 12)
                startButton
            }
            VStack(alignment: .leading, spacing: 12) {
                title
                startButton
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Learning")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text("A daily queue from the words and sentences you saved while reading.")
                .font(.subheadline)
                .foregroundStyle(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startButton: some View {
        Button(action: onStartSession) {
            Label(
                sessionCount == 1 ? "Study 1 card" : "Study \(sessionCount) cards",
                systemImage: "play.fill"
            )
        }
        .buttonStyle(.borderedProminent)
        .tint(Palette.terracotta)
        .controlSize(.large)
        .disabled(sessionCount == 0)
        .accessibilityHint(
            sessionCount == 0
                ? "There are no due or new cards."
                : "Starts due learning cards, due reviews, then new cards."
        )
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
