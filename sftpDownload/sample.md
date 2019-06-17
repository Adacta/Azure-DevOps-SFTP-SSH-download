# Samples

## SSH Connection example

```json
{
    "Url":  "ssh://test2:22/",
    "Data":  {
                 "host":  "test2",
                 "port":  "22",
                 "privateKey":  "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: DES-EDE3-CBC,0iitugHJQVJCBcyLV/NM3F2bSSRZJhJ5Pw==\n-----END RSA PRIVATE KEY-----"
             },
    "Auth":  {
                 "parameters":  {
                                    "username":  "test3",
                                    "password":  "123"
                                },
                 "scheme":  "UsernamePassword"
             }
}
```
