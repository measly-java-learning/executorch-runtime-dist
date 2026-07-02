# ExecuTorch Runtime Dist

The purpose of this repository is to provide PIC assets for desktop builds of [ExecuTorch](https://github.com/pytorch/executorch) for use with JNI.  Meta has a JNI interface layer for ExecuTorch, but it is focused on Android and requires fbjni.  The default build configuration for ExecuTorch is *not* to build with `-fPIC`, making it difficult to link into a JVM via JNI.

This repository hosts CI infrastructure to create and attest these builds such that they can be safely and responsibly consumed elsewhere.
