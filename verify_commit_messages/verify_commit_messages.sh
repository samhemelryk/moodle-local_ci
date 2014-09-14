#!/bin/bash
# $gitcmd: Path to the git CLI executable
# $gitdir: Directory containing git repo
# $initialcommit: hash of the initial commit
# $finalcommit: hash of the final commit
# $issuecode: code of the issue to verify
# $debug: to return results in human-readable format for debugging

# Verify commit messages observe Moodle's rules (MDLSITE-1990):
#   http://docs.moodle.org/dev/Commit_cheat_sheet#Provide_clear_commit_messages
#
# If the script finds any problem (error or warning), it ends with non-zero exit code
# and reports all the problems (1 by line) in error output with format:
#   COMMIT (short) * LEVEL (error or warning) * DESCRIPTION (details)
# Example:
#   1234abcd*error*Commit messages does not start with issue code.
#   2345bcde*warning*Body line too long (184 > 132).
#   2345cdef*error*Subject line too long (75 > 72).

# Don't be strict. Script has own error control handle
set +e

# Verify everything is set
required="gitcmd gitdir initialcommit finalcommit"
for var in $required; do
    if [ -z "${!var}" ]; then
        echo "Error: ${var} environment variable is not defined. See the script comments."
        exit 1
    fi
done

# no issue passed, apply for general MDL-xxxxx template.
hasissuecode=1
templateissuecode=MDL-[0-9]{3,6}
if [[ -z ${issuecode} ]]; then
    hasissuecode=""
fi
# ensure we have debug defined, defaulting to disabled.
debug="${debug:-}"

# calculate some variables
mydir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

cd ${gitdir}

# verify initial commit exists
${gitcmd} rev-parse --quiet --verify ${initialcommit} > /dev/null
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    echo "Error: initial commit does not exist (${initialcommit})"
    exit 1
fi

# verify final commit exists
${gitcmd} rev-parse --quiet --verify ${finalcommit} > /dev/null
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    echo "Error: final commit does not exist (${finalcommit})"
    exit 1
fi

# verify initial commit is ancestor of final commit
${gitcmd} merge-base --is-ancestor ${initialcommit} ${finalcommit}
if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
    echo "Error: unrelated commits are not comparable (${initialcommit} and ${finalcommit})"
    exit 1
fi

# get all the commits between both commits
commits=$(${gitcmd} rev-list --abbrev-commit ${initialcommit}..${finalcommit})

# iterate over all commits, performing checks and reporting problems/status
totalnumproblems=0
mergecommits=0
for c in ${commits}; do
    ismerge=""
    numproblems=0
    message=$(${gitcmd} show -s --pretty=format:%B ${c})
    # detect if the commit is a merge
    numparents=$(${gitcmd} cat-file -p ${c} | grep '^parent ' | wc -l)
    if [[ ${numparents} -gt 1 ]]; then
        ismerge=1
        mergecommits=$((mergecommits+1))
    fi
    # output information with debug enabled
    if [[ $debug ]];then
        echo "------------------------------"
        if [[ $ismerge ]]; then
            echo "commit: ${c} (merge), message:"
        else
            echo "commit: ${c}, message:"
        fi
        echo "${message}"
        echo
        echo "Results:"
    fi
    # merge commits
    if [[ -n $ismerge ]]; then
        # verify it's using standard message "Merge branch ... of ...". Error.
        if [[ ! "${message}" =~ ^Merge\ branch\ .*\ of\ (git|http) ]];then
            echo "${c}*error*The merge commit does not match the expected 'Merge branch ... of ...' format."
            numproblems=$((numproblems+1))
        fi
        # verify the branch contains the template issue code. Warn.
        if [[ ! "${message}" =~ ${templateissuecode} ]];then
            echo "${c}*warning*The merge commit does not match the expected issue code ${templateissuecode}."
            numproblems=$((numproblems+1))
        fi
        # verify the branch contains the issue code. Warn.
        if [[ ${hasissuecode} ]]; then
            if [[ ! "${message}" =~ ${issuecode} ]];then
                echo "${c}*warning*The merge commit does not match the expected issue code ${issuecode}."
                numproblems=$((numproblems+1))
            fi
        fi
    # normal commits
    else
        # loop line by line, different checks will be performed
        currentline=1
        missingissuecode=""
        codearea=""
        while read line; do
            # check 1st line
            if [[ ${currentline} -eq 1 ]]; then
                # verify subject begins with template issue code + space. Error.
                if [[ ! "${line}" =~ ^${templateissuecode}\  ]];then
                    echo "${c}*error*The commit does not begin with the expected issue code ${templateissuecode} and a space."
                    numproblems=$((numproblems+1))
                    missingissuecode=1
                fi
                # verify subject begins with matching issue code + space. Error.
                if [[ ${hasissuecode} ]]; then
                    if [[ ! "${line}" =~ ^${issuecode}\  ]]; then
                        # If the issue code in anywhere else in the message relax it a bit. Warning. Else Error.
                        if [[ "${message}" =~ ${issuecode}\  ]]; then
                            echo "${c}*warning*The commit contains the expected issue code ${issuecode} but in wrong place. That is allowed only for epics or issues with subtasks. Verify it."
                        else
                            echo "${c}*error*The commit does not contain the expected issue code ${issuecode} and a space."
                        fi
                        numproblems=$((numproblems+1))
                    fi
                fi
                # verify there is an area after the issue code, ending in :. Warn.
                if [[ ! ${missingissuecode} ]]; then
                    if [[ ! "${line}" =~ ^${templateissuecode}\ ([^:]*):\  ]];then
                        echo "${c}*warning*The commit does not define a code area ending with a colon and a space after the issue code."
                        numproblems=$((numproblems+1))
                    else
                        codearea=${BASH_REMATCH[1]}
                    fi
                fi
                # verify the area in subject line is < 30 chars long. Warn.
                if [[ ${codearea} ]]; then
                    codearealen=$(echo "${codearea}" | wc -c)
                    if [[ ${codearealen} -gt 30 ]];then
                        echo "${c}*warning*The commit code area '${codearea}' is too long (${codearealen} > 30)"
                        numproblems=$((numproblems+1))
                    fi
                fi
                # verify there are no multiple : in the subject line. Error.
                # verify subject line is <= 72 chars long. Error.
                len=$(echo "${line}" | wc -c)
                if [[ ${len} -gt 72 ]]; then
                    echo "${c}*error*The first line has more than 72 characters (found: ${len})"
                    numproblems=$((numproblems+1))
                fi
            # check 2nd line
            elif [[ ${currentline} -eq 2 ]]; then
                # verify 2nd line is empty line. Error.
                if [[ -n ${line} ]]; then
                    echo "${c}*error*The second line must be empty (found: '${line}')"
                    numproblems=$((numproblems+1))
                fi
            # check rest of lines
            else
                # verify 3rd and following lines are <= 132 chars long. Warn.
                len=$(echo "${line}" | wc -c)
                if [[ ${len} -gt 132 ]]; then
                    echo "${c}*error*The line #${currentline} has more than 132 characters (found: ${len})"
                    numproblems=$((numproblems+1))
                fi
            fi
            currentline=$((currentline+1))
        done < <(echo "${message}") # end of line by line
        # verify there are no 2 lines. Error.
        if [[ ${currentline} -eq 3 ]]; then
            echo "${c}*error*Commit message cannot have 2 lines."
            numproblems=$((numproblems+1))
        fi
    fi
    if [[ ${debug} ]];then
        if [[ ${numproblems} -gt 0 ]];then
            echo "(found ${numproblems} problems)"
        else
            echo "Ok"
        fi
    fi
    totalnumproblems=$((totalnumproblems+numproblems))
done
# should not be more than 1 merge commit when inspecting dev branches.
if [[ ${mergecommits} -gt 1 ]]; then
    echo "${initialcommit}...${finalcommit}*warning*Multiple merge commits (${mergecommits}) found. Please verify."
    totalnumproblems=$((totalnumproblems+numproblems))
fi
# exiting with number of problems.
if [[ ${debug} ]];then
    echo
    echo "Total number of problems found: ${totalnumproblems} (used as exit code)."
fi
exit ${totalnumproblems}