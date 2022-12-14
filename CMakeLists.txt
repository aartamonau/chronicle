# Used when built as part of couchbase server only.

IF (NOT DEFINED INST_LIBDIR)
  MESSAGE(FATAL_ERROR "INST_LIBDIR is not defined.")
ENDIF ()

IF (NOT TARGET ns_realclean)
  MESSAGE(FATAL_ERROR "ns_realclean target does not exist.")
ENDIF ()

SET (REBAR_OPTS -C "${CMAKE_CURRENT_SOURCE_DIR}/rebar2.config")

REBAR (TARGET chronicle REBAR_OPTS ${REBAR_OPTS} CLEAN_HOOK ns_realclean)
REBAR (TARGET chronicle_dump REBAR_OPTS ${REBAR_OPTS}
  COMMAND escriptize NOCLEAN DEPENDS chronicle)

SET(INSTALL_DIR "${INST_LIBDIR}/chronicle")

# This assumes that rebar2 is used.
INSTALL (DIRECTORY ebin DESTINATION "${INSTALL_DIR}")
INSTALL (PROGRAMS chronicle_dump DESTINATION bin)

# priv/ only exists on Linux currently, so make this OPTIONAL
INSTALL (DIRECTORY priv OPTIONAL DESTINATION "${INSTALL_DIR}")
