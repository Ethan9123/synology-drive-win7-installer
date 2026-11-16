@{
    SchemaVersion = 1
    # Fixed source identities, NOT a claim of Win7 deployment approval.
    # Change version, URL, filename, size and digest together after reviewing a new sample.
    Packages = @(
        @{
            Id = 'Synology'
            Version = '4.0.3-17892'
            FileName = 'Synology Drive Client-4.0.3-17892-x86.exe'
            Url = 'https://global.synologydownload.com/download/Utility/SynologyDriveClient/4.0.3-17892/Windows/Installer/i686/Synology%20Drive%20Client-4.0.3-17892-x86.exe'
            Size = 71342576
            Sha256 = 'a8cfce9ee1a1c6705b28c013d5ab92029e499c34f6d8142dcb69f4d8e124c4a4'
            SignaturePolicy = 'Publisher'
            Publisher = 'Synology Inc.'
            Acceptance = 'PendingWin7Validation'
        }
        @{
            Id = 'VxKex'
            Version = '1.2.3.2466'
            FileName = 'KexSetup_Release_1_2_3_2466.exe'
            Url = 'https://github.com/YuZhouRen86/VxKex-NEXT/releases/download/1.2.3.2466/KexSetup_Release_1_2_3_2466.exe'
            Size = 5025016
            Sha256 = 'e8fa07f6919f48bd3c381dedcbd54dabc147c824522f1ac2a8fc60366f43f535'
            SignaturePolicy = 'UnsignedPinned'
            Publisher = ''
            Acceptance = 'PendingWin7Validation'
        }
    )
}
