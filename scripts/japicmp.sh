#!/bin/bash
#
# Copyright © 2021 Apple Inc. and the ServiceTalk project authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

SCRIPT=$(basename "${BASH_SOURCE:-stidn}")

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
  echo "# Usage"
  echo "#    ${SCRIPT} <old_version> (<new_version> (<group_id>))"
  echo "# Description"
  echo "# This script compares versions for binary backward compatibility."
  echo "# It must be run from a directory containing a clone of ServiceTalk"
  echo "# if optional <new_version> unspecified or string 'local' then compare to local build"
  echo "# if optional <group_id> unspecified then local dir gradle 'group' property will be used"
  echo "# Comparisons against local build assume that './gradlew build' has been run."
  exit 1
fi

function bom_artifacts() {
  local GROUP_ID=${1}
  local VERSION=${2}
  mvn -N -U dependency:get -DgroupId="${GROUP_ID}" -DartifactId="servicetalk-bom" \
    -Dversion="${VERSION}" -Dpackaging=pom -Dtransitive=false >/dev/null
  (xsltproc - \
    "${BASEPATH}/servicetalk-bom/${VERSION}/servicetalk-bom-${VERSION}.pom" |
    grep '^servicetalk-' |
    sort -) <<"XSLTDOC"
<?xml version="1.0"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:p="http://maven.apache.org/POM/4.0.0"
    xmlns:exslt="http://exslt.org/common" version="1.0" extension-element-prefixes="exslt">
  <xsl:output omit-xml-declaration="yes" indent="no" method="text"/>
  <xsl:template match="/">
    <xsl:for-each select="//p:dependencyManagement/p:dependencies/p:dependency">
      <xsl:call-template name="value-of-template">
        <xsl:with-param name="select" select="p:artifactId"/>
      </xsl:call-template>
      <xsl:value-of select="'&#10;'"/>
    </xsl:for-each>
  </xsl:template>
  <xsl:template name="value-of-template">
    <xsl:param name="select"/>
    <xsl:value-of select="$select"/>
    <xsl:for-each select="exslt:node-set($select)[position()&gt;1]">
      <xsl:value-of select="'&#10;'"/>
      <xsl:value-of select="."/>
    </xsl:for-each>
  </xsl:template>
</xsl:stylesheet>
XSLTDOC
}

MVN_REPO="$(mvn help:evaluate -Dexpression=settings.localRepository -q -DforceStdout)"

JAPICMP_VERSION="0.15.3"
JAR_DIR="${MVN_REPO}/com/github/siom79/japicmp/japicmp/${JAPICMP_VERSION}"
JAR_FILE="${JAR_DIR}/japicmp-${JAPICMP_VERSION}-jar-with-dependencies.jar"
if [ ! -f "${JAR_FILE}" ]; then
  mvn -N dependency:get \
    -DgroupId=com.github.siom79.japicmp -DartifactId=japicmp -Dversion="${JAPICMP_VERSION}" \
    -Dtransitive=false -Dclassifier=jar-with-dependencies 2>&1 || exit 1
fi

OLD_ST_VERSION="${1:-}"
LOCAL="${2:-local}"
NEW_ST_VERSION="${2:-$(./gradlew properties | grep '^version: ' | cut -f 2 -d ' ')}"
GROUP_ID="${3:-$(./gradlew properties | grep '^group: ' | cut -f 2 -d ' ')}"
GROUP_PATH=$(echo "${GROUP_ID}" | tr '.' '/')
BASEPATH="${MVN_REPO}/${GROUP_PATH}/"

if [ -z "${OLD_ST_VERSION}" ]; then
  echo "# Error: Old version not specified."
  exit 1
fi

OLD_ARTIFACTS="$(bom_artifacts "${GROUP_ID}" "${OLD_ST_VERSION}")"

if [ "${LOCAL}" = "local" ]; then
  NEW_ARTIFACTS="$(find servicetalk-* -type d -maxdepth 0 | sort -)"
else
  NEW_ARTIFACTS="$(bom_artifacts "${GROUP_ID}" "${NEW_ST_VERSION}")"
fi

# All servicetalk modules except:
# servicetalk-benchmarks, servicetalk-bom, servicetalk-examples, servicetalk-gradle-plugin-internal
ARTIFACTS="$(comm -1 -2 \
  <(echo "${OLD_ARTIFACTS}" | tr ' ' '\n') \
  <(echo "${NEW_ARTIFACTS}" | tr ' ' '\n') |
  grep -v -- '-\(benchmarks\|bom\|examples\|gradle-plugin-internal\)$')"

for ARTIFACT_ID in ${ARTIFACTS}; do
  OLD_JAR="${BASEPATH}/${ARTIFACT_ID}/${OLD_ST_VERSION}/${ARTIFACT_ID}-${OLD_ST_VERSION}.jar"

  FOUND_OLD=$( (mvn -N -U dependency:get \
    -DgroupId="${GROUP_ID}" -DartifactId="${ARTIFACT_ID}" \
    -Dversion="${OLD_ST_VERSION}" -Dtransitive=false 1>&2 >/dev/null && echo true) ||
    echo false)

  if [ "${FOUND_OLD}" = "false" ] || [ ! -f "${OLD_JAR}" ]; then
    echo "# Error  : old artifact (${ARTIFACT_ID}::${OLD_ST_VERSION}) not found"
    echo ""
    exit 1
  fi

  if [ "${LOCAL}" = "local" ]; then
    NEW_JAR="${ARTIFACT_ID}/build/libs/${ARTIFACT_ID}-${NEW_ST_VERSION}.jar"
  else
    FOUND_NEW=$( (mvn -N -U dependency:get -DgroupId="${GROUP_ID}" -DartifactId="${ARTIFACT_ID}" \
      -Dversion="${NEW_ST_VERSION}" -Dtransitive=false 1>&2 >/dev/null && echo true) ||
      echo false)
    NEW_JAR="${BASEPATH}/${ARTIFACT_ID}/${NEW_ST_VERSION}/${ARTIFACT_ID}-${NEW_ST_VERSION}.jar"
  fi

  if [ "${FOUND_NEW:-}" = "false" ] || [ ! -f "${NEW_JAR}" ]; then
    echo "# Error : new artifact (${ARTIFACT_ID}::${NEW_ST_VERSION}) not found"
    echo ""
    exit 1
  fi

  java -jar "$JAR_FILE" --no-error-on-exclusion-incompatibility --report-only-filename \
    -a protected -b --ignore-missing-classes --include-synthetic \
    --old "${OLD_JAR}" --new "${NEW_JAR}" | grep -v -- '--ignore-missing-classes'
  echo ""
done
