import RevenueCat
import StoreKit
import SwiftUI

// MARK: - Product Identifiers

enum SubscriptionProduct: String, CaseIterable {
    case monthly = "com.demo.MilkTeaSticker.pro.monthly"
    case yearly  = "com.demo.MilkTeaSticker.pro.yearly"
    /// Non-consumable one-time purchase; StoreKit keeps it in
    /// currentEntitlements forever, so it grants Pro like a subscription.
    case lifetime = "com.demo.MilkTeaSticker.pro.lifetime"

    var isSubscription: Bool { self != .lifetime }

    var displayName: String {
        switch self {
        case .monthly: return String(localized: "月度会员")
        case .yearly:  return String(localized: "年度会员")
        case .lifetime: return String(localized: "终身会员")
        }
    }

    var badge: String {
        switch self {
        case .monthly: return "📅"
        case .yearly:  return "🎉"
        case .lifetime: return "👑"
        }
    }

    /// Price line under the plan name, built from the App Store price so it
    /// shows the right currency in every storefront.
    func subtitle(for product: Product?) -> String {
        guard let product else {
            guard AppLocale.isChinese else { return "" }
            switch self {
            case .monthly: return "¥6/月"
            case .yearly:  return "¥38/年（约¥3.2/月）"
            case .lifetime: return String(localized: "一次购买，永久使用")
            }
        }
        switch self {
        case .monthly:
            return String(localized: "\(product.displayPrice)/月")
        case .yearly:
            let perMonth = (product.price / 12).formatted(product.priceFormatStyle)
            return String(localized: "\(product.displayPrice)/年（约\(perMonth)/月）")
        case .lifetime:
            return String(localized: "一次购买，永久使用")
        }
    }

    /// "$19.99/year" for the free-trial disclosure under the subscribe button.
    func pricePerPeriod(_ displayPrice: String) -> String {
        switch self {
        case .monthly: return String(localized: "\(displayPrice)/月")
        case .yearly:  return String(localized: "\(displayPrice)/年")
        case .lifetime: return displayPrice
        }
    }

    var fallbackDisplayPrice: String {
        guard AppLocale.isChinese else { return "" }
        switch self {
        case .monthly: return "¥6"
        case .yearly:  return "¥38"
        case .lifetime: return "¥98"
        }
    }

    /// "Save N%" badge for the yearly plan, compared with twelve monthly payments.
    func savingTag(monthly: Product?, yearly: Product?) -> String? {
        guard self == .yearly else { return nil }
        var percent = 47
        if let monthly, let yearly, monthly.price > 0 {
            let ratio = (yearly.price as NSDecimalNumber).doubleValue / ((monthly.price as NSDecimalNumber).doubleValue * 12)
            percent = Int((1 - ratio) * 100)
        } else if !AppLocale.isChinese {
            return nil
        }
        guard percent > 0 else { return nil }
        return String(localized: "省\(percent)%")
    }
}

// MARK: - Subscription Manager

/// Prices, trials and the paywall come straight from StoreKit 2; purchases and
/// restores go through RevenueCat so its dashboard sees every subscriber.
/// Pro is granted if either StoreKit or RevenueCat says so, so a RevenueCat
/// outage or misconfiguration never locks out someone who paid Apple.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = [] {
        didSet { DiaryFont.premiumUnlocked = !purchasedProductIDs.isEmpty }
    }
    /// Products whose free trial this Apple ID can still claim.
    @Published private(set) var trialEligibleProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""

    private static let revenueCatAPIKey = "appl_lIqBUxFFkpTKcHYRZjcTmMecOUn"

    private var transactionListener: Task<Void, Never>?
    private var customerInfoListener: Task<Void, Never>?
    /// Products RevenueCat reports as active, from its latest CustomerInfo.
    private var revenueCatProductIDs: Set<String> = []

    var isProUser: Bool {
        return !purchasedProductIDs.isEmpty
    }

    var ownsLifetime: Bool {
        purchasedProductIDs.contains(SubscriptionProduct.lifetime.rawValue)
    }

    /// Pro via an auto-renewing plan, which the user may want to manage or
    /// cancel (e.g. after also buying lifetime).
    var hasActiveSubscription: Bool {
        purchasedProductIDs.contains { $0 != SubscriptionProduct.lifetime.rawValue }
    }

    private init() {
        #if DEBUG
        Purchases.logLevel = .debug
        #endif
        Purchases.configure(withAPIKey: Self.revenueCatAPIKey)
        transactionListener = listenForTransactions()
        customerInfoListener = listenForCustomerInfo()
        Task { await loadProducts() }
        Task {
            await updatePurchasedProducts()
            await syncExistingSubscriptionIfNeeded()
        }
    }

    deinit {
        transactionListener?.cancel()
        customerInfoListener?.cancel()
    }

    // MARK: - Load Products

    func loadProducts() async {
        guard products.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let ids = SubscriptionProduct.allCases.map(\.rawValue)
            let storeProducts = try await Product.products(for: ids)
            products = storeProducts.sorted { ($0.price as NSDecimalNumber).doubleValue < ($1.price as NSDecimalNumber).doubleValue }
            await updateTrialEligibility()
        } catch {
            errorMessage = String(localized: "无法加载订阅信息，请检查网络连接")
            showError = true
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async -> Bool {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await Purchases.shared.purchase(product: StoreProduct(sk2Product: product))
            if result.userCancelled { return false }
            applyCustomerInfo(result.customerInfo)
            await updatePurchasedProducts()
            return true
        } catch ErrorCode.paymentPendingError {
            errorMessage = String(localized: "购买正在等待确认")
            showError = true
            return false
        } catch ErrorCode.purchaseCancelledError {
            return false
        } catch {
            errorMessage = String(localized: "购买失败：\(error.localizedDescription)")
            showError = true
            return false
        }
    }

    // MARK: - Restore

    func restorePurchases() async {
        isLoading = true
        defer { isLoading = false }
        if let info = try? await Purchases.shared.restorePurchases() {
            applyCustomerInfo(info)
        }
        await updatePurchasedProducts()
    }

    func redeemOfferCode() {
        SKPaymentQueue.default().presentCodeRedemptionSheet()
    }

    // MARK: - Transaction Listener

    /// RevenueCat finishes transactions itself; this only refreshes Pro state
    /// for renewals, refunds and purchases made outside the app.
    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await _ in Transaction.updates {
                await self?.updatePurchasedProducts()
            }
        }
    }

    private func listenForCustomerInfo() -> Task<Void, Never> {
        Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                guard let self else { return }
                self.applyCustomerInfo(info)
                await self.updatePurchasedProducts()
            }
        }
    }

    private static let didSyncExistingKey = "revenueCatDidSyncExistingSubscription"

    /// Subscribers from before RevenueCat (1.2 and earlier) are unknown to it
    /// until their purchases are synced once. StoreKit 2 syncs silently, with
    /// no Apple ID prompt.
    private func syncExistingSubscriptionIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didSyncExistingKey) else { return }
        guard !purchasedProductIDs.isEmpty else { return }
        guard let info = try? await Purchases.shared.syncPurchases() else { return }
        defaults.set(true, forKey: Self.didSyncExistingKey)
        applyCustomerInfo(info)
        await updatePurchasedProducts()
    }

    private func applyCustomerInfo(_ info: CustomerInfo) {
        revenueCatProductIDs = Set(info.entitlements.active.values.map(\.productIdentifier))
    }

    // MARK: - Verify & Update

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                purchased.insert(transaction.productID)
            }
        }
        purchasedProductIDs = purchased.union(revenueCatProductIDs)
        await updateTrialEligibility()
    }

    private func updateTrialEligibility() async {
        var eligible: Set<String> = []
        for product in products {
            guard let subscription = product.subscription,
                  subscription.introductoryOffer?.paymentMode == .freeTrial else { continue }
            if await subscription.isEligibleForIntroOffer {
                eligible.insert(product.id)
            }
        }
        trialEligibleProductIDs = eligible
    }

    private func checkVerified<T>(_ result: StoreKit.VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Helpers

    func product(for sub: SubscriptionProduct) -> Product? {
        products.first { $0.id == sub.rawValue }
    }

    /// Length of the free trial this user would get, or nil when there is none
    /// or they've already used it. Only day and week trials are sold.
    func freeTrialDays(for sub: SubscriptionProduct) -> Int? {
        guard let product = product(for: sub),
              trialEligibleProductIDs.contains(product.id),
              let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        switch offer.period.unit {
        case .day: return offer.period.value
        case .week: return offer.period.value * 7
        default: return nil
        }
    }
}
