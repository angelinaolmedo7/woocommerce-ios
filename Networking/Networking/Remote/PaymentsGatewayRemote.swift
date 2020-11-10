import Foundation

/// Payment Gateways Endpoints
///
public class PaymentsGatewayRemote: Remote {

    /// Retrieves all of the `PaymentGateways` available.
    ///
    /// - Parameters:
    ///     - siteID: Site for which we'll fetch remote paymet gateways.
    ///     - completion: Closure to be executed upon completion.
    ///
    public func loadAllPaymentGateways(siteID: Int64, completion: @escaping (Result<[PaymentGateway], Error>) -> Void) {
        let request = JetpackRequest(wooApiVersion: .mark3, method: .get, siteID: siteID, path: Constants.path)
        let mapper = PaymentGatewayListMapper(siteID: siteID)
        enqueue(request, mapper: mapper, completion: completion)
    }
}

// MARK: Constant
private extension PaymentsGatewayRemote {
    enum Constants {
        static let path = "payment_gateways"
    }
}
