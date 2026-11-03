@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # console output of a CLI tool, not pipeline data
        'PSAvoidUsingWriteHost',
        # small internal helpers; no -WhatIf semantics needed
        'PSUseShouldProcessForStateChangingFunctions',
        # Get-Safe / socket cleanup intentionally swallow errors
        'PSAvoidUsingEmptyCatchBlock'
    )
}
