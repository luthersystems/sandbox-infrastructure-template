{
  "terraform": [
    {
      "backend": [
        {
          "s3": [
            {
              "bucket": $bucket,
              "encrypt": true,
              "key": $key,
              "kms_key_id": $kms_key_id,
              "region": $region,
              "workspace_key_prefix": $workspace_key_prefix
            }
          ]
        }
      ]
    }
  ]
}
