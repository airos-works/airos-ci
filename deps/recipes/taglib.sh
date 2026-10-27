# TagLib 2.0.2 with utfcpp 4.0.5 (airos-works/taglib airos-2.0.2, submodule from
# airos-works/utfcpp): Amp's tag reading.
VERSION=2.0.2
SUMMARY="TagLib audio metadata library"
COPYRIGHT="2002-2024 Scott Wheeler, TagLib contributors"
LICENSE="GNU LGPL v2.1"
build() {
	cmake_build -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF
}
