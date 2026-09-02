import SwiftUI

if KeroCommandLine.shouldRun {
    KeroCommandLine.main()
}

if ScrollBench.shouldRun {
    ScrollBench.main()
}

if ResourceBench.shouldRun {
    ResourceBench.main()
}

keroApp.main()
