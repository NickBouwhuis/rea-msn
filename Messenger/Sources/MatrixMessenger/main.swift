import MatrixKit
import MessengerUI

// Messenger for Matrix: the same windows on a Matrix account (matrix-rust-sdk).
MainActor.assumeIsolated { MessengerLauncher.run(MatrixProfile()) }
