import QuartzCore

@MainActor
final class PaneTransitionReplicaLayer {
    let rootLayer = CALayer()
    private let snapshotLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()

    static func install(
        in hostLayer: CALayer,
        snapshot: CGImage,
        fromFrame: CGRect,
        scale: CGFloat,
        cornerRadius: CGFloat,
        borderWidth: CGFloat,
        borderColor: CGColor
    ) -> PaneTransitionReplicaLayer {
        let replica = PaneTransitionReplicaLayer()

        replica.rootLayer.frame = fromFrame
        replica.rootLayer.masksToBounds = true
        replica.rootLayer.cornerRadius = cornerRadius
        replica.rootLayer.cornerCurve = .continuous
        replica.rootLayer.zPosition = 100

        replica.snapshotLayer.frame = CGRect(
            origin: .zero,
            size: fromFrame.size
        )
        replica.snapshotLayer.contents = snapshot
        replica.snapshotLayer.contentsGravity = .topLeft
        replica.snapshotLayer.contentsScale = scale

        let fullRect = CGRect(origin: .zero, size: fromFrame.size)
        let fullPath = CGPath(
            roundedRect: fullRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        replica.maskLayer.path = fullPath
        replica.maskLayer.fillColor = CGColor(gray: 0, alpha: 1)

        replica.borderLayer.path = fullPath
        replica.borderLayer.fillColor = nil
        replica.borderLayer.strokeColor = borderColor
        replica.borderLayer.lineWidth = borderWidth

        replica.rootLayer.addSublayer(replica.snapshotLayer)
        replica.rootLayer.mask = replica.maskLayer
        replica.rootLayer.addSublayer(replica.borderLayer)

        hostLayer.addSublayer(replica.rootLayer)
        return replica
    }

    func animateToFrame(
        _ targetFrame: CGRect,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        let localTargetRect = CGRect(
            x: targetFrame.minX - rootLayer.frame.minX,
            y: targetFrame.minY - rootLayer.frame.minY,
            width: targetFrame.width,
            height: targetFrame.height
        )
        let cornerRadius = rootLayer.cornerRadius
        let targetPath = CGPath(
            roundedRect: localTargetRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = maskLayer.path
        maskAnimation.toValue = targetPath
        maskAnimation.duration = duration
        maskAnimation.timingFunction = timingFunction
        maskAnimation.fillMode = .forwards
        maskAnimation.isRemovedOnCompletion = false
        maskLayer.add(maskAnimation, forKey: "pathAnimation")
        maskLayer.path = targetPath

        let borderAnimation = CABasicAnimation(keyPath: "path")
        borderAnimation.fromValue = borderLayer.path
        borderAnimation.toValue = targetPath
        borderAnimation.duration = duration
        borderAnimation.timingFunction = timingFunction
        borderAnimation.fillMode = .forwards
        borderAnimation.isRemovedOnCompletion = false
        borderLayer.add(borderAnimation, forKey: "pathAnimation")
        borderLayer.path = targetPath
    }

    func remove() {
        maskLayer.removeAllAnimations()
        borderLayer.removeAllAnimations()
        rootLayer.removeFromSuperlayer()
    }
}
