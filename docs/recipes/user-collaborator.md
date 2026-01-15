---
layout: template
title: Atelier
description: Templates for creating a more secure new user account in AWS for external collaborators to share data
category: AWS
tags:
  - aws
  - s3
  - file-transfer
last_updated: 2026-01-14
---

## Overview

Below are IAM policy templates based on extent of permissions given to the user on the collaborator's side. Some example use cases would be:

- Providing a collaborator with access to exisiting data held in an S3 bucket to support transfer of data from you to them (one-way download)

!!! info "Use the ['Download only' template](#__tabbed_1_1)"

- Providing a collaborator with access to an S3 bucket to support transfer of data from them to you as part of an ongoing project (upload and download)

!!! info "Use the ['Upload/Download' template](#__tabbed_1_2)"

---

## Templates

=== "Download only"

    This template is designed for creating an IAM policy to attach to an AWS new user account that allows specific collaborators access to download files (read-only) from certain S3 buckets.

    First, copy this JSON script as the template that will be modified.

    ``` json title="Download only template" linenums="1"
    { 
      "Version": "2012-10-17", 
      "Id": "collaborator-username-download",
      "Statement": [ 
        { 
          "Sid": "AllowListBucketInSpecificPrefixes", 
          "Effect": "Allow", 
          "Action": ["s3:ListBucket"], 
          "Resource": "arn:aws:s3:::my-data-bucket", 
          "Condition": { 
            "StringLike": { 
              "s3:prefix": [ 
                "exports/researchA/", 
                "exports/researchB/subset/"
              ] 
            } 
          } 
        }, 
        { 
          "Sid": "AllowGetObjectsInSpecificPrefixes", 
          "Effect": "Allow", 
          "Action": [
            "s3:GetObject",
            "s3:GetObjectVersion"
          ], 
          "Resource": [ 
            "arn:aws:s3:::my-data-bucket/exports/researchA/*", 
            "arn:aws:s3:::my-data-bucket/exports/researchB/subset/*"
          ] 
        }, 
        { 
          "Sid": "ExplicitDenyWriteOrDelete", 
          "Effect": "Deny", 
          "Action": [ 
            "s3:PutObject", 
            "s3:DeleteObject", 
            "s3:DeleteObjectVersion", 
            "s3:AbortMultipartUpload", 
            "s3:PutObjectAcl", 
            "s3:RestoreObject" 
          ], 
          "Resource": "arn:aws:s3:::my-data-bucket/exports/" 
        }
      ] 
    }
    ```

    Next, modify the template to use the specific bucket name and prefixes as needed for the collaboration.

    ``` json title="Line 9" linenums="8" hl_lines="2"
          "Action": ["s3:ListBucket"], 
          "Resource": "arn:aws:s3:::my-data-bucket", # Change here
          "Condition": { 
    ```
    ``` json title="Lines 13 & 14" linenums="12" hl_lines="2-3"
          "s3:prefix": [ 
            "exports/researchA/", # Change / Add Here
            "exports/researchB/subset/" # Change / Add here
          ] 
    ```
    ``` json title="Lines 27 & 28" linenums="26" hl_lines="2-3"
          "Resource": [ 
            "arn:aws:s3:::my-data-bucket/exports/researchA/*", # Change / Add here
            "arn:aws:s3:::my-data-bucket/exports/researchB/subset/*" # Change / Add here
          ] 
    ```
    ``` json title="Line 42" linenums="41" hl_lines="2"
          ], 
          "Resource": "arn:aws:s3:::my-data-bucket/exports/" # Change here
        }
    ```

    Last, give the policy a specific ID for this collaboration. The policy will be removed after the collaboration ends or as needed.

    ``` json title="Line 3" linenums="1" hl_lines="3"
    { 
      "Version": "2012-10-17",
      "Id": "collaborator-username-download", # Change here
      "Statement": [
    ```


=== "Upload/Download"

    This template is designed for creating an IAM policy to attach to an AWS new user account that allows specific collaborators access to upload and download files (read-write-delete) from certain S3 buckets.

    First, copy this JSON script as the template that will be modified.

    ``` json title="Upload/Download template" linenums="1"
    { 
      "Version": "2012-10-17", 
      "Id": "collaborator-username-readwrite", 
      "Statement": [ 
        { 
          "Sid": "AllowListBucketInSpecificPrefixes", 
          "Effect": "Allow", 
          "Action": ["s3:ListBucket"], 
          "Resource": "arn:aws:s3:::my-data-bucket", 
          "Condition": { 
            "StringLike": { 
              "s3:prefix": [ 
                "exports/researchA/",
                "exports/researchB/subset/" 
              ] 
            } 
          } 
        }, 
        { 
          "Sid": "AllowReadWriteObjectsInSpecificPrefixes", 
          "Effect": "Allow", 
          "Action": [ 
            "s3:GetObject", 
            "s3:GetObjectVersion", 
            "s3:PutObject" 
          ], 	
          "Resource": [ 
            "arn:aws:s3:::my-data-bucket/exports/researchA/*", 
            "arn:aws:s3:::my-data-bucket/exports/researchB/subset/*" 
          ] 
        }, 
        { 
          "Sid": "OptionalAllowDeleteInSpecificPrefixes", 
          "Effect": "Allow", 
          "Action": [ 
            "s3:DeleteObject", 
            "s3:DeleteObjectVersion", 
            "s3:AbortMultipartUpload" 
          ], 
          "Resource": [ 
            "arn:aws:s3:::my-data-bucket/exports/researchA/*", 
            "arn:aws:s3:::my-data-bucket/exports/researchB/subset/*" 
          ] 
        } 
      ] 
    }
    ```

    Next, modify the template to use the specific bucket name and prefixes as needed for the collaboration.

    ``` json title="Line 9" linenums="8" hl_lines="2"
          "Action": ["s3:ListBucket"], 
          "Resource": "arn:aws:s3:::my-data-bucket", # Change here
          "Condition": { 
    ```
    ``` json title="Lines 13 & 14" linenums="12" hl_lines="2-3"
          "s3:prefix": [ 
            "exports/researchA/", # Change / Add Here
            "exports/researchB/subset/" # Change / Add here
          ] 
    ```
    ``` json title="Lines 28 & 29" linenums="27" hl_lines="2-3"
          "Resource": [ 
            "arn:aws:s3:::my-data-bucket/exports/researchA/*", # Change / Add here
            "arn:aws:s3:::my-data-bucket/exports/researchB/subset/*" # Change / Add here
          ] 
    ```
    ``` json title="Lines 41 & 42" linenums="40" hl_lines="2-3"
          "Resource": [ 
            "arn:aws:s3:::my-data-bucket/exports/researchA/*", # Change / Add here
            "arn:aws:s3:::my-data-bucket/exports/researchB/subset/*" # Change / Add here
          ] 
    ```

---

Now the rest of the process is completed within the AWS Console using the steps below.

- Create the IAM policy:

  >IAM console > Policies > Create policy > JSON

  >Paste the JSON above with your values > Create policy.

- Create a group and attach the policy:

  >IAM console > User groups > Create group (e.g., ExternalS3ReadOnly)

  >Attach the S3ReadOnlySpecificPrefixes policy to the group.

- Create the IAM user and add to the group:

  >IAM console > Users > Create user

  >Add the user to ExternalS3ReadOnly

  >Create Access Key with CLI programmatic access

  >Save the Access Key ID and Secret Access Key and share securely.
