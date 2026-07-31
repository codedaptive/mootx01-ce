import Foundation
import LocalAuthentication

enum SecretSyncAuthorizationScope: Sendable, Equatable {
  case authority
  case foregroundHydration
  case background
}

final class SecretSyncAuthorizedContext: @unchecked Sendable {
  let scope: SecretSyncAuthorizationScope
  let identifier: UUID
  let localAuthenticationContext: LAContext?

  init(
    scope: SecretSyncAuthorizationScope,
    identifier: UUID = UUID(),
    localAuthenticationContext: LAContext
  ) {
    self.scope = scope
    self.identifier = identifier
    self.localAuthenticationContext = localAuthenticationContext
  }

  static func fixture(
    scope: SecretSyncAuthorizationScope,
    identifier: UUID
  ) -> SecretSyncAuthorizedContext {
    SecretSyncAuthorizedContext(
      scope: scope,
      identifier: identifier,
      localAuthenticationContext: LAContext()
    )
  }
}

protocol SecretSyncAuthorizationOperating: Sendable {
  func authorize(
    scope: SecretSyncAuthorizationScope
  ) async throws -> SecretSyncAuthorizedContext

  func invalidate(_ context: SecretSyncAuthorizedContext) async
}

actor SecretSyncSystemAuthorization: SecretSyncAuthorizationOperating {
  func authorize(
    scope: SecretSyncAuthorizationScope
  ) async throws -> SecretSyncAuthorizedContext {
    guard scope != .background else {
      throw SecretSyncCustodyError.backgroundOperationDenied
    }
    let context = LAContext()
    context.interactionNotAllowed = false
    // Authority calls may not consume a previous lock-screen biometric match.
    // Foreground-session reuse comes from retaining this one evaluated context,
    // never from a process-wide biometric reuse duration.
    context.touchIDAuthenticationAllowableReuseDuration = 0
    let reason: String
    switch scope {
    case .authority:
      reason = "Authorize a protected security operation"
    case .foregroundHydration:
      reason = "Unlock protected content for this session"
    case .background:
      throw SecretSyncCustodyError.backgroundOperationDenied
    }
    do {
      var availabilityError: NSError?
      guard context.canEvaluatePolicy(
        .deviceOwnerAuthentication,
        error: &availabilityError
      ) else {
        throw SecretSyncCustodyError.authorizationFailed
      }
      _ = try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason
      )
      return SecretSyncAuthorizedContext(
        scope: scope,
        localAuthenticationContext: context
      )
    } catch let error as SecretSyncCustodyError {
      context.invalidate()
      throw error
    } catch {
      context.invalidate()
      throw SecretSyncCustodyError.authorizationFailed
    }
  }

  func invalidate(_ context: SecretSyncAuthorizedContext) {
    context.localAuthenticationContext?.invalidate()
  }
}

/// One explicitly owned foreground authorization session.
///
/// The session is deliberately type-distinct from authority authorization, so
/// a cached foreground context cannot be passed to a policy-authority method.
public actor SecretSyncForegroundAuthorizationSession {
  private let context: SecretSyncAuthorizedContext
  private let operations: any SecretSyncAuthorizationOperating
  private var isInvalidated = false

  fileprivate init(
    context: SecretSyncAuthorizedContext,
    operations: any SecretSyncAuthorizationOperating
  ) {
    self.context = context
    self.operations = operations
  }

  func authorizedContext() throws -> SecretSyncAuthorizedContext {
    guard !isInvalidated, context.scope == .foregroundHydration else {
      throw SecretSyncCustodyError.authorizationFailed
    }
    return context
  }

  /// Ends the foreground session and invalidates its authorization context.
  public func invalidate() async {
    guard !isInvalidated else { return }
    isInvalidated = true
    await operations.invalidate(context)
  }
}

actor SecretSyncLocalAuthorization {
  private let operations: any SecretSyncAuthorizationOperating

  init(
    operations: any SecretSyncAuthorizationOperating =
      SecretSyncSystemAuthorization()
  ) {
    self.operations = operations
  }

  func authorityContext() async throws -> SecretSyncAuthorizedContext {
    try await operations.authorize(scope: .authority)
  }

  func beginForegroundSession()
    async throws -> SecretSyncForegroundAuthorizationSession
  {
    let context = try await operations.authorize(
      scope: .foregroundHydration
    )
    return SecretSyncForegroundAuthorizationSession(
      context: context,
      operations: operations
    )
  }

  func context(
    for scope: SecretSyncAuthorizationScope
  ) async throws -> SecretSyncAuthorizedContext {
    guard scope != .background else {
      // Deny before delegating, so background code cannot reach an operation
      // that could prompt or touch a private Keychain handle.
      throw SecretSyncCustodyError.backgroundOperationDenied
    }
    return try await operations.authorize(scope: scope)
  }

  func invalidate(_ context: SecretSyncAuthorizedContext) async {
    await operations.invalidate(context)
  }
}
