import AppIntents

/// Common execution and authentication policy for intents touching an estate.
public protocol MootEstateIntent: AppIntent {}

extension MootEstateIntent {
    @available(anyAppleOS 27.0, *)
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }

    public static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }
}
