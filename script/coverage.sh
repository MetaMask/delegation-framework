# NOTE: Expects to be run from inside the script directory.

set -e # Exit on error

cd .. 

folder_path="coverage"

if [ ! -d "$folder_path" ]; then
    mkdir -p "$folder_path"
    echo "Folder created at: $folder_path"
else
    echo "Folder already exists at: $folder_path"
fi

# Configuration: Define test files for different EVM versions
declare -a SHANGHAI_TESTS=(
    "test/helpers/AaveLending.t.sol"
    # Add more shanghai tests here in the future
    # "test/helpers/AnotherShanghaiTest.t.sol"
)

declare -a CANCUN_TESTS=(
    # Add cancun tests here when needed
    # "test/helpers/CancunTest.t.sol"
)

# Function to build match patterns for forge coverage
build_match_patterns() {
    local tests=("$@")
    local patterns=""
    
    for test in "${tests[@]}"; do
        if [[ -n "$patterns" ]]; then
            patterns="$patterns --match-path *$(basename "$test")"
        else
            patterns="--match-path *$(basename "$test")"
        fi
    done
    
    echo "$patterns"
}

# Function to build no-match patterns for forge coverage
build_no_match_patterns() {
    local tests=("$@")
    local patterns=""
    
    for test in "${tests[@]}"; do
        if [[ -n "$patterns" ]]; then
            patterns="$patterns --no-match-path *$(basename "$test")"
        else
            patterns="--no-match-path *$(basename "$test")"
        fi
    done
    
    echo "$patterns"
}

echo "Running coverage with inline EVM version flags..."
echo "-----------------------------------------------"

# Build list of all special EVM tests to exclude from default London run
ALL_SPECIAL_EVM_TESTS=("${SHANGHAI_TESTS[@]}" "${CANCUN_TESTS[@]}")
LONDON_NO_MATCH_PATTERNS=$(build_no_match_patterns "${ALL_SPECIAL_EVM_TESTS[@]}")

# Generate coverage for London EVM (default) - exclude special EVM tests
if [[ -n "$LONDON_NO_MATCH_PATTERNS" ]]; then
    echo "Running coverage for London EVM..."
    echo "Excluding: ${ALL_SPECIAL_EVM_TESTS[*]}"
    forge coverage --evm-version london --report lcov --skip scripts $LONDON_NO_MATCH_PATTERNS --report-file "$folder_path/lcov-london.info"
else
    echo "Running coverage for London EVM - no exclusions..."
    forge coverage --evm-version london --report lcov --skip scripts --report-file "$folder_path/lcov-london.info"
fi

# Generate coverage for Shanghai EVM tests if any exist
if [ ${#SHANGHAI_TESTS[@]} -gt 0 ]; then
    echo "Running coverage for Shanghai EVM..."
    echo "Including: ${SHANGHAI_TESTS[*]}"
    SHANGHAI_MATCH_PATTERNS=$(build_match_patterns "${SHANGHAI_TESTS[@]}")
    forge coverage --evm-version shanghai --report lcov --skip scripts $SHANGHAI_MATCH_PATTERNS --report-file "$folder_path/lcov-shanghai.info"
fi

# Generate coverage for Cancun EVM tests if any exist
if [ ${#CANCUN_TESTS[@]} -gt 0 ]; then
    echo "Running coverage for Cancun EVM..."
    echo "Including: ${CANCUN_TESTS[*]}"
    CANCUN_MATCH_PATTERNS=$(build_match_patterns "${CANCUN_TESTS[@]}")
    forge coverage --evm-version cancun --report lcov --skip scripts $CANCUN_MATCH_PATTERNS --report-file "$folder_path/lcov-cancun.info"
fi

# Build the list of coverage files to merge
COVERAGE_FILES=("$folder_path/lcov-london.info")
if [ ${#SHANGHAI_TESTS[@]} -gt 0 ]; then
    COVERAGE_FILES+=("$folder_path/lcov-shanghai.info")
fi
if [ ${#CANCUN_TESTS[@]} -gt 0 ]; then
    COVERAGE_FILES+=("$folder_path/lcov-cancun.info")
fi

# Merge the lcov files
echo "Merging coverage reports..."
echo "Files to merge: ${COVERAGE_FILES[*]}"
lcov \
    --rc branch_coverage=1 \
    $(printf -- "--add-tracefile %s " "${COVERAGE_FILES[@]}") \
    --output-file "$folder_path/lcov.info"

# Filter out test, mock, and script files
lcov \
    --rc branch_coverage=1 \
    --remove "$folder_path/lcov.info" \
    --output-file "$folder_path/filtered-lcov.info" \
    "test/*.*"

# Generate summary
lcov \
    --rc branch_coverage=1 \
    --list "$folder_path/filtered-lcov.info"

# Open more granular breakdown in browser
if [ "$CI" != "true" ]
then
    genhtml \
        --rc branch_coverage=1 \
        --output-directory "$folder_path" \
        "$folder_path/filtered-lcov.info"
    open "$folder_path/index.html"
fi 