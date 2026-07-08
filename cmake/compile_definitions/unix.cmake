# unix specific compile definitions
# put anything here that applies to both linux and macos

list(APPEND SUNSHINE_EXTERNAL_LIBRARIES
        ${CURL_LIBRARIES})

# add install prefix to assets path if not already there
# (skip if the user gave an absolute path — e.g. a dev build pointing at
#  the build tree's assets/)
if(NOT IS_ABSOLUTE "${SUNSHINE_ASSETS_DIR}")
    set(SUNSHINE_ASSETS_DIR "${CMAKE_INSTALL_PREFIX}/${SUNSHINE_ASSETS_DIR}")
endif()
