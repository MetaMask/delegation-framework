# NOTE: Expects to be run from inside the script directory.

set -e # Exit on error

cd .. 

folder_path="coverage"

if [ ! -d "$folder_path" ]; then
    # If not, create the folder
    mkdir -p "$folder_path"
    echo "Folder created at: $folder_path"
else
    echo "Folder already exists at: $folder_path"
fi



# Generates lcov.info
forge coverage --report lcov --skip scripts --report-file "$folder_path/lcov.info"

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