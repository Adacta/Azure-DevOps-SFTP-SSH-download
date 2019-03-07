tfx extension create --manifest-globs vss-extension.json --rev-version
tfx extension publish --manifest-globs vss-extension.json

REM tfx login -u https://marketplace.visualstudio.com
REM --share-with yourOrganization
