/// Resolves the SSH destination a pane is currently talking to.
///
/// Sources, in priority order: the live `ssh` process found by the
/// foreground probe, the pane's `ssh ...` command title, the inferred
/// connection label, and finally the remote shell-integration context.
/// Shared by remote image paste and "Copy Path" on remote panes.
enum PaneSSHDestinationResolver {
    static func destination(from auxiliaryState: PaneAuxiliaryState) -> SSHDestination? {
        if let destination = auxiliaryState.raw.foregroundSSHDestination {
            return destination
        }

        if let title = WorklaneContextFormatter.trimmed(auxiliaryState.raw.metadata?.title),
           let destination = WorklaneContextFormatter.sshDestination(fromCommandTitle: title) {
            return destination
        }

        if let label = WorklaneContextFormatter.trimmed(auxiliaryState.presentation.sshConnectionLabel) {
            return SSHDestination(target: label)
        }

        if let shellContext = auxiliaryState.raw.shellContext,
           shellContext.scope == .remote,
           let host = WorklaneContextFormatter.trimmed(shellContext.host) {
            let user = WorklaneContextFormatter.trimmed(shellContext.user)
            return SSHDestination(
                target: user.map { "\($0)@\(host)" } ?? host,
                user: user,
                host: host
            )
        }

        return nil
    }
}
