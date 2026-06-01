#!/bin/bash

###############################################################################
# Script Name: vsh (Virtual Shell)
# Description: A client-side tool to interact with a custom archive server.
#              It allows creating, extracting, listing, and interactively 
#              browsing archives using a virtual file system structure.
#
# Usage:       ./vsh <HOST> <PORT> <MODE> [ARCHIVE_NAME]
#
# Arguments:
#   HOST       : IP address or hostname of the remote server.
#   PORT       : Port number to connect to (via netcat).
#   MODE       : Operation mode (see below).
#   ARCHIVE    : Name of the archive file (required for create, extract, browse).
#
# Modes:
#   -list      : List all archives available on the server.
#   -create    : Create an archive from the current local directory and send it.
#   -extract   : Download an archive and extract it to the current directory.
#   -browse    : Enter an interactive virtual shell to navigate the archive.
#
# Interactive Commands (Browse Mode):
#   - ls       : List directory contents (supports -l for details, -a for hidden).
#   - cd       : Change current virtual directory (supports relative/absolute paths).
#   - pwd      : Print current virtual working directory.
#   - cat      : Display content of a file within the archive.
#   - mkdir    : Create a new directory in the archive (supports -p).
#   - touch    : Create a new empty file in the archive.
#   - rm       : Remove files or directories recursively.
#
# File Format: [Header:Body_Start_Line]
#              The archive is split into a metadata Header (file info, permissions)
#              and a Body (actual file contents), separated by calculated offsets.
#
# Authors:     Ferrasse--Jamaux Tom (Browse logic)
#              Dufrenot Amaury (Server, Create, List, Extract logic)
# Date:        2025-12-18
###############################################################################

# Redirect standard error to /dev/null to hide system errors from the user
exec 2>/dev/null

# --- ARGUMENT CHECKING ---
if [ $# -lt 3 ]; then
    echo "Usage: $0 HOST PORT -MODE [ARCHIVE]"
    exit 1
fi

HOST="$1"
PORT="$2"
MODE="$3"
ARCHIVE="$4"

###############################################################################
# Network Functions
# Description: Helper functions to handle communication with the server via netcat.
###############################################################################

# Function: get_archive
# Description: Downloads the specified archive from the server to the local machine.
get_archive() {
    echo "GET $ARCHIVE" | nc -w 1 "$HOST" "$PORT" > "$ARCHIVE"
}

# Function: put_archive
# Description: Uploads the local archive file to the server.
#              Includes a small sleep to ensure the server socket is ready.
put_archive() {
    sleep 0.2
    { echo "PUT $ARCHIVE"; cat "$ARCHIVE"; } | nc -w 1 "$HOST" "$PORT"
}

###############################################################################
# Mode: List
# Description: Asks the server to list all available archives.
###############################################################################
if [ "$MODE" == "-list" ]; then
    echo "LIST" | nc -w 1 "$HOST" "$PORT"
    exit 0
fi

###############################################################################
# Mode: Create
# Description: Traverses the current directory recursively to build the custom 
#              archive format. It separates metadata (Header) and content (Body).
###############################################################################
if [ "$MODE" == "-create" ]; then
    if [ -z "$ARCHIVE" ]; then echo "Archive name missing"; exit 1; fi
    
    # Create temporary files for the header and body sections
    HEADER="header_$$.tmp"
    BODY="body_$$.tmp"
    > "$HEADER"
    > "$BODY"
    
    # OFFSET tracks the line number in the BODY where the file content starts
    OFFSET=1
    
    # 1. Loop through all directories to create the structure
    find . -type d | while read -r current_dir; do
        # Convert local path (./folder) to archive path format (folder\)
        clean_path="${current_dir#./}"
        if [ "$clean_path" == "." ]; then
            clean_path="\\"
        else
            clean_path="${clean_path//\//\\}"
            # Ensure path ends with a backslash
            if [[ "$clean_path" != *\\ ]]; then clean_path="${clean_path}\\"; fi
        fi
        
        # Write directory entry to header
        echo "directory $clean_path" >> "$HEADER"
        
        # 2. Loop through files inside the current directory
        find "$current_dir" -maxdepth 1 ! -path "$current_dir" | while read -r file; do
            filename=$(basename "$file")
            
            # Exclude script files and temp files from the archive
            if [[ "$filename" == "vsh.sh" || "$filename" == "server.sh" || "$filename" == "$ARCHIVE" || "$filename" == *.tmp ]]; then
                continue
            fi

            perms=$(stat -c "%A" "$file")
            
            if [ -d "$file" ]; then
                # Directory entry inside the list (size 0, offset 0)
                echo "$filename $perms 0 0 0" >> "$HEADER"
            else
                # File entry: Calculate lines and size
                lines=$(wc -l < "$file")
                size=$(wc -c < "$file")
                echo "$filename $perms $size $OFFSET $lines" >> "$HEADER"
                
                # Append actual file content to BODY if not empty
                if [ "$lines" -gt 0 ]; then
                    cat "$file" >> "$BODY"
                    OFFSET=$((OFFSET + lines))
                fi
            fi
        done
        # Mark end of directory block
        echo "@" >> "$HEADER"
    done

    # Calculate where the BODY starts (Header length + 2 lines for metadata)
    header_len=$(wc -l < "$HEADER")
    body_start=$((header_len + 2))
    
    # Assemble the final archive: [Offsets] + [Header] + [Body]
    echo "2:$body_start" > "$ARCHIVE"
    cat "$HEADER" >> "$ARCHIVE"
    cat "$BODY" >> "$ARCHIVE"
    
    # Cleanup and Upload
    rm "$HEADER" "$BODY"
    put_archive
    rm "$ARCHIVE"
    exit 0
fi

###############################################################################
# Mode: Extract
# Description: Downloads an archive and reconstructs the file system locally.
#              Parses the header to create directories and extract file content.
###############################################################################
if [ "$MODE" == "-extract" ]; then
    get_archive
    
    # Parse the first line to get Header and Body start offsets
    first_line=$(head -n 1 "$ARCHIVE")
    header_start=$(echo "$first_line" | cut -d: -f1)
    body_start=$(echo "$first_line" | cut -d: -f2)
    
    current_extract_dir="."
    
    # Read the Header section line by line
    tail -n +$header_start "$ARCHIVE" | head -n $((body_start - header_start)) | while read -r line; do
        
        # Case 1: Directory definition (create the folder)
        if [[ "$line" == directory* ]]; then
            raw_path=$(echo "$line" | cut -d' ' -f2)
            # Convert archive path (\) to Linux path (/)
            linux_path=$(echo "$raw_path" | sed 's/\\/\//g')
            if [ "$linux_path" == "/" ]; then 
                current_extract_dir="."
            else 
                current_extract_dir="./$linux_path"
                mkdir -p "$current_extract_dir"
            fi
            
        # Case 2: File entry (extract content)
        elif [[ "$line" != "@" ]]; then
            read name rights size offset length <<< "$line"
            
            # Ensure it's a file and not a subdirectory marker
            if [ -n "$name" ] && [[ "$rights" != d* ]]; then
                target_file="$current_extract_dir/$name"
                
                # Extract content using sed (from start_line to end_line)
                if [ "$length" -gt 0 ]; then
                    start_line=$((body_start + offset - 1))
                    end_line=$((start_line + length - 1))
                    sed -n "${start_line},${end_line}p" "$ARCHIVE" > "$target_file"
                else
                    touch "$target_file"
                fi
                
                # Restore executable permissions if needed
                if [[ "$rights" == *x* ]]; then chmod +x "$target_file"; fi
            fi
        fi
    done
    rm "$ARCHIVE"
    exit 0
fi

# --- BROWSE MODE ---
if [ "$MODE" == "-browse" ]; then
	# Fetch the archive locally
	get_archive
    
    	# Adaptation: Map the generic variable name 'archive' to the script argument
    	archive="$ARCHIVE"

	# --- Global Configuration & Archive Parsing ---
	# Extract header and body start lines from the first line of the archive (format: header:body)
	header_start_line=$(head -n 1 "$archive" | cut -d':' -f1)
	body_start_line=$(head -n 1 "$archive" | cut -d':' -f2)

	# Ensure values are treated as integers
	header_start_line=$(($header_start_line+0))
	body_start_line=$(($body_start_line+0))

	# 'cd_num' tracks the line number of the current directory in the archive
	cd_num=$header_start_line

	# Extract the root path name from the header line
	root=$(sed -n "${header_start_line}p" "$archive" | cut -d' ' -f2)

	###############################################################################
	# Function: ls_f
	# Description: Lists files and directories in the current virtual directory.
	# Options:     -a (all), -l (long format), -al
	###############################################################################
	ls_f() {
		# Parse arguments passed in the global variable $more
		local more=$1
		read arg1 rest <<< "$more"
		if [[ "$arg1" == -* ]]; then
			option="$arg1"
			list_input="$rest"
		else
			option=""
			list_input="$more"
		fi
		
		# Extract the block of text representing the current directory.
	    	# Logic: Read from line (cd_num + 1) until the next line containing only '@'.
		local var=$((cd_num + 1))
		local dir=$(sed -n "${var},\$p" "$archive" | sed -n "/^@$/ {q}; p")
		local var2
		local dir2
		
		# Set flags for options a l and al using case
		local a=0
		local l=0
		case $option in
		-a) a=1;;
		-l) l=1;;
		-al|-la) a=1; l=1;;
		\?)echo "Usage invalide: only options [a] [l]"; return 1;;
		esac
		
		local files_to_process
		local flag
		local target_line
		
		# --- Long Format Output (-l) ---
		if [ $l -eq 1 ]; then
			if [ -z "$list_input" ]; then
				files_to_process=$(echo "$dir" | awk '{print $1}')
			else
				files_to_process="$list_input"
			fi

			for file in $files_to_process; do
				flag='0'
				while read -r name rights size _; do
					# Handle hidden files if -a is not set
					if [ $a -eq 0 ]; then
						if [[ $name == \.* ]]; then	
				    			continue 1
				    		fi
				    	fi
					if [[ "$name" == "$file" ]]; then
					    	flag='1'
						# If it's a directory, we need to fetch its contents for display or just list it
						if [[ "$rights" == d* ]]; then
						target_line=$(grep -nF "directory" "$archive" | grep "\\$name$" | head -n 1 | cut -d: -f1)
						if [[ -n "$target_line" && ! -z "$list_input" ]]; then
							echo "$name :"
							local new_var=$((target_line + 1))
							# Extract sub-directory content
							while read -r name rigths size _; do
							    echo "$rights $size $name"
							done <<< $(sed -n "${new_var},\$p" "$archive" | sed -n "/^@$/ {q}; p")
							echo " "
						else
							echo "$rights $size $name"
						fi
						else
						echo "$rights $size $name"
						fi
					    break
					fi
				done <<< "$dir"
			    if [ "$flag" == "0" ] && [ "$a" -ne 0 ]; then
			    	echo "ls: cannot access $file: No such file or directory"
			    fi
			done
		
		# --- Standard Format Output (Short) ---
		else
			local ls_output=''
			if [ -z "$list_input" ]; then
				# List all files in current directory
				while read -r name rights _; do
					if [ $a -eq 0 ]; then
						if [[ "$name" == \.* ]]; then
							continue
						fi
					fi
					# Append visual indicators (slash for dir, asterisk for exec)
					if [[ "$rights" == d* ]]; then
						ls_output="$ls_output $name\\"
					elif [[ "$rights" == ???x* ]]; then
						ls_output="$ls_output $name*"
					else
						ls_output="$ls_output $name"
					fi
				done<<<"$dir"		
				echo "$ls_output"
			else 
				# List specific files passed as arguments
				local flag1=1
				for file in $list_input; do
					while read -r name rights size _; do
						if [[ "$name" == "$file" ]]; then
						flag1=0
						fi
						# If argument is a directory, list its content
					    	if [[ "$rights" == d* ]]; then
							new_cd=$(grep -n "\\\\$file$" "$archive" | cut -d: -f1)
							var2=$((new_cd + 1))
							dir2=$(sed -n "${var2},\$p" "$archive" | sed -n "/^@$/ {q}; p")
						fi
					done<<<"$dir"
					if [ $flag1 -eq 1 ]; then
						echo "ls : can not access '$file': No file or directory"
					else 
						echo "$file:"
						while read -r name rights _; do
							if [[ $name == \.* ]]; then
								continue
							fi
							if [[ "$rights" == d* ]]; then
								ls_output="$ls_output $name\\"
							elif [[ "$rights" == ???x* ]]; then
								ls_output="$ls_output $name*"
							else
								ls_output="$ls_output $name"
							fi
						done<<<"$dir2"
						echo "$ls_output"
						echo ""
					fi
					ls_output=''
				done
			fi
		fi
	}

	###############################################################################
	# Function: pwd_f
	# Description: Prints the current working directory.
	#              Converts the internal archive path representation to a standard path.
	###############################################################################
	pwd_f() {
		local current=$(sed -n "${cd_num}p" "$archive" | cut -d' ' -f2)
		# Escape backslashes for sed substitution
		local escaped_root=$(echo "$root" | sed 's/\\/\\\\/g')
		# Remove root prefix to get relative paths
		local relative_path=$( echo "$current" | sed "s/${escaped_root}//")
		local final_path="\\${relative_path}"
		echo "$final_path"
	}

	###############################################################################
	# Function: cd_f
	# Description: Simulates directory navigation by updating the global $cd_num pointer
	#         	   which references a specific line in the $archive file.
	###############################################################################
	cd_f() {
		local more=$1
		local nb_word=$(echo "$more" | wc -w)

		# CASE 1: A specific path is provided
		if [ $nb_word -eq 1 ]; then
			local current_cd_num=$cd_num
			local movements=$(echo "$more" | tr '[\\]' '[ ]')
			local path_flag=0

			# Absolute path handling: if starts with '\', reset to root line
			if [[ "$more" == \\* ]]; then 
				current_cd_num=$header_start_line
			fi
			for part in $movements; do
				case "$part" in
				..)

					# --- Navigate to Parent ---
               		# Retrieve current path from the archive at the current line index
					local path=$(sed -n "${current_cd_num}p" "$archive" | cut -d' ' -f2 )
					# Check if not already at root (root ends with '\')
					if [ "${path: -1}" != '\' ]; then
						# Trim the last directory level using regex
						local new_path=$(echo "$path" | sed 's/\\[a-zA-Z_0-9]*$//')

						# Formatting fix for root edge case
						if [ "$new_path\\" == "$root" ]; then
						path="$new_path\\"
						else
						    path="$new_path"
						fi

						# Update line pointer by searching for the parent path in the archive
						current_cd_num=$(grep -n "${path//\\/\\\\}$" "$archive" |  cut -d: -f1)
					fi
				;;
				*)
					# --- Navigate to Child ---
					local current_path=$(sed -n "${current_cd_num}p" "$archive" | cut -d' ' -f2)
					local target_path

					# Construct target path string
					if [ "${current_path: -1}" = '\' ]; then
						target_path="$current_path$part"
					else
					    	target_path="$current_path\\$part"
					fi
					
					# Search for exact target path match in archive (escaping backslashes)
					local search_pattern=" ${target_path//\\/\\\\}$"
					local found_num=$(grep -n "$search_pattern" "$archive" | cut -d: -f1 | head -n 1)

					if [ -n "$found_num" ]; then
					    	current_cd_num=$found_num
					else
						# Error handling: Stop if any segment of the path is invalid
						echo "bash: cd: $more: No such file or directory"
						path_flag=1
						break
					fi
				;;
				esac
			done

			# Transactional update: only change global pointer if the entire path was valid
			if [ "$path_flag" -eq 0 ]; then
				cd_num=$current_cd_num
			fi

		# CASE 2: No arguments (cd command alone) resets to root	
		elif [ -z "$more" ]; then
			cd_num=$header_start_line
		# CASE 3: Invalid argument count
		else
			echo "Usage : cd [path]"
		fi
	}

	###############################################################################
	# Function: cat_f
	# Description: Displays the content of a file.
	#              Uses the offset and line count stored in the file info.
	###############################################################################
	cat_f() {
		# Get current directory block
		local dir=$(sed -n "${cd_num},\$p" "$archive" | sed -n "/^@$/ {q}; p")
		local more=$1
		
		for file in $more;do
			# Extract metadata: columns 4 (start offset) and 5 (number of rows)
			read start row_nb <<< $(echo "$dir" | grep -m 1 "${file} " | cut -d' ' -f4,5)
			if [ -z "$start" ]; then
				echo "cat: $file: No such file"
			else
				# Calculate absolute line numbers in the archive
				local first_row=$((body_start_line + start - 1))
				local last_row=$((first_row + row_nb - 1))
				
				if [ "$row_nb" -gt 0 ]; then
					sed -n "${first_row},${last_row}p" "$archive"
				fi
			fi
		done
	}

	###############################################################################
	# Function: mkdir_f
	# Description: Creates a new directory in the archive.
	#              Modifies the archive in-place using sed to insert metadata.
	# Option: -p (create directory into directory)
	###############################################################################
	mkdir_f() {

		# Nested function to handle the actual insertion logic
		create_new_directory() {
			local current_directory_line=$1
			local new_directory=$2

			# 1. Add entry to the parent directory block
			local insert_line=$((current_directory_line + 1))
			local current_block=$(sed -n "${insert_line},\$p" "$archive" | sed -n "/^@$/ {q}; p")
			
			# Check for existence and determine insertion point
			while read -r name rights _; do
				if [[ "$new_directory" == "$name" ]]; then
					return 1
				elif [[ "$rights" == d* ]]; then
					((insert_line++))
				else
					break
				fi
			done <<< "$current_block"

			# Construct full path for the new directory	
			local new_directory_path=$(sed -n "${current_directory_line}p" "$archive" | cut -d' ' -f2 )
			if [[ "$new_directory_path" != *\\ ]]; then
			    new_directory_path="${new_directory_path}\\"
			fi
			new_directory_path="${new_directory_path}$d"
			local tmp_new_directory_path="$new_directory_path"

			# Insert the directory entry into the parent block
			sed -i "${insert_line}i $d drwxr-xr-x 0" "$archive"
			
			# 2. Create the new directory definition block at the end of the header section
			local checked_directory_line
			line_new_directory=$(head -n 1 "$archive"| cut -d':' -f2)
			local escaped_path="${new_directory_path//\\/\\\\}"
			
			# Insert delimiter (@) and directory declaration
			sed -i "${line_new_directory}i @\ndirectory ${escaped_path}" "$archive"

			line_new_directory=$(( $line_new_directory + 1 ))

			# 3. Update global indices (we added lines, so offsets shift)
			update_line_index 3
		}
		
		# --- Main mkdir Logic ---
		local line_new_directory
		local shift=0
		local more=$1
		read -r arg1 rest <<< "$more"
		local list_dir=""

		# Handle -p option (parents)
		if [[ "$arg1" == "-p" ]]; then
			option="$arg1"
			list_dir="$rest"
		else
			option=""
			list_dir="$more"
		fi

		if [ -z "$list_dir" ]; then
			echo "mkdir: missing operand"
			return 1
		fi
		local current_directory_line=$cd_num

		if [ "$option" == "-p" ]; then
			# Create nested directories
			line_new_directory="$current_directory_line"
			list_dir=$(echo "$list_dir" | tr '[\\]' '[ ]')
			for d in $list_dir; do
				create_new_directory $line_new_directory "$d"
			done
		else
			# Create standard directories
			for d in $list_dir; do
				case $d in
				*[\<\>\?,/\\\|*\$\[\]#\!-]*)echo "mkdir: cannot create directory '$d': Invalide argument";;
				*)create_new_directory $current_directory_line $d;;
				esac
			done
		fi
	}

	###############################################################################
	# Function: update_line_index
	# Description: Updates the global header offsets and shifts file indices within
	#              the archive when lines are added or removed.
	# Arguments:
	#   $1 - shift_total: Amount to shift the body_start_line
	#   $2 - shift_body:  Amount to shift file content indices (optional)
	#   $3 - flag:        Threshold index for shifting (optional)
	#   $4 - is_rm:       Boolean flag if called from remove (optional)
	###############################################################################
	update_line_index() {
		local shift_total=$1
		local shift_body=$2
		local flag=$3
		local is_rm=$4
		local tmp_file="${archive}.tmp"
		
		# Update body start pointer
		((body_start_line += shift_total))
		echo "${header_start_line}:${body_start_line}" > "$tmp_file"
		empty_space=$(( header_start_line - 2 )) #2 count the first line (header:body) and the first header line
		if [ "$empty_space" -gt 0 ]; then
			for ((i=1; i<=empty_space; i++)); do
				echo "">> "$tmp_file"
			done
		fi
		# Process the rest of the archive line by line to update indices
		if [[ -n "$shift_body" && "$shift_body" -ne 0 ]]; then 
			tail -n +$header_start_line "$archive" | while read -r line; do 
				read -r name rights size index more <<< "$line"
				
				# Check if the line represents a file (starts with -) and needs shifting
				if [[ "$rights" == -* && ${#rights} -eq 10 && $index -gt $flag ]]; then
					if [ -n "$is_rm" ]; then
						((index -= shift_body))
					fi
					echo "$name $rights $size $index $more" >> "$tmp_file"
				else
					echo "$line" >> "$tmp_file"
				fi
			done
		else
			# Just append the rest if no body shifting is required
			tail -n +"$header_start_line" "$archive" >> "$tmp_file"
		fi

		mv "$tmp_file" "$archive"
	}

	###############################################################################
	# Function: touch_f
	# Description: Creates an empty file in the current directory.
	###############################################################################
	touch_f() {
		
		local files=$1
		for name in $files; do
			case $name in
				*[\<\>\?,/\\\|*\$\[\]#\!-]*)echo "touch: cannot touch '$name': Invalide argument"; return 1 ;;
				*)
				# Set file database
				local rights="-rw-r--r--"
				local size=0
				local first_line=$(( $(wc -l < "$archive") - $body_start_line + 2 ))
				local line_nb=0
				local file_info="$name $rights $size $first_line $line_nb"

				# Check for duplicates in current directory
				local current_block=$(sed -n "${cd_num},\$p" "$archive" | sed -n "/^@$/ {q}; p")
				while read -r line; do
					local existing_name=$(echo "$line" | cut -d' ' -f1)
					if [[ "$name" == "$existing_name" ]]; then
						return 1
					fi
				done <<< $current_block
				local nb_line_current_block=$(echo "$current_block" | wc -l)
				local insert_line=$(( cd_num + nb_line_current_block ))
				
				# Insert file entry
				sed -i "${insert_line}i $file_info" "$archive" 
				
				# Update indices (added 1 line)
				update_line_index 1
			;;
			esac
		done
	}

	###############################################################################
	# Function: rm_f
	# Description: Removes files or directories (recursively for directories).
	###############################################################################
	rm_f() {
		# Internal helper to remove a file
		rm_file() {
			local current_line_num=$1
			read -r name rights size index line_nb <<< $( sed -n "${current_line_num}p" "$archive")
			
			# Calculate where the actual content is stored in the body
			local shift=$(( index + body_start_line - 1 ))
			
			# Delete content lines from body
			if [ $line_nb -ne 0 ]; then
				sed -i "${shift},+${line_nb}d" "$archive"
			fi
			
			# Delete the metadata entry
			(( line_nb -- ))
			sed -i "${current_line_num}d" "$archive"
			(( line_nb ++ ))
			
			# Update indices (content removed + metadata line removed)
			update_line_index -1 $line_nb $index 1
		}
		
		# Internal helper to remove a directory recursively
		rm_directory() {
			local current_index=$1
			local dir_name=$2
			local target_dir_path
			local parent_path=$(sed -n "${current_index}p" "$archive" | cut -d' ' -f2)
			
			# Construct full path
			if [[ "$parent_path" != "$root" ]]; then
				target_dir_path="$parent_path\\$dir_name"
			else
				target_dir_path="$parent_path$dir_name"
			fi
			
			local target_dir_index=$(grep -n "${target_dir_path//\\/\\\\}$" "$archive" |  cut -d':' -f1)
			local update_tdi=$((target_dir_index + 1))
			local target_block=$(sed -n "${update_tdi},\$p" "$archive" | sed -n "/^@$/ {q}; p")
			
			# Recursively delete contents
			if [[ -n "$target_block" ]]; then 
				while read -r name rights _; do
					if [[ "$rights" == d* ]]; then
						rm_directory "$target_dir_index" "$name"
					elif [[ "$rights" == -* ]]; then
						current_line_num=$(( target_dir_index + 1 ))
						rm_file "$current_line_num"
					elif [[ "$name" == @ ]]; then
						# Safety catch for block delimiter
						supp_at_index=$((target_dir_index + 1))
						sed -i "${supp_at_index},${target_dir_index}d" "$archive"
						break
					fi
				done<<<$target_block
			fi
			
			# Remove the directory declaration line itself
			target_index=$(grep -n "${target_dir_path//\\/\\\\}$" "$archive" |  cut -d':' -f1)
			sed -i "${target_index},+1d" "$archive"
			
			# Remove entry from parent directory block
			current_block=$(sed -n "${current_index},\$p" "$archive" | sed -n "/^@$/ {q}; p")
			local i=0
			while read -r name rights _; do
				if [[ "$name" == "$dir_name" ]]; then
					supp_at_index=$((current_index + i))
					sed -i "${supp_at_index}d" "$archive"
					break
				fi
				((i++))
			done<<<"$current_block"
			update_line_index -3
		}
		
		# --- Main rm Logic ---
		local current_block=$(sed -n "${cd_num},\$p" "$archive" | sed -n "/^@$/ {q}; p")
		local flag=0
		local flag_d=0
		local i=0
		local more=$1
		
		# Identify if target is file or directory
		while read -r name rights _; do
			if [[ $name == $more ]]; then
				flag=1
				if [[ "$rights" == d* ]]; then
					flag_d=1
				fi
				break
			fi
			((i++))
		done<<<"$current_block"
		
		if [ "$flag" -eq 0 ]; then
			echo "rm: cannot remove '$more': No such file or directory"
			return 1
		fi
		if [ "$flag_d" -eq 1 ]; then
			rm_directory "$cd_num" "$more"
		else
			local target_index=$((i + cd_num))
			rm_file "$target_index"
		fi
	}

	# --- Main Execution Loop ---
	# The whole browse mode works inside the while loop
	while true; do
		echo -n "vsh:>"
		read -r cmd more
		case "$cmd" in
		pwd)	pwd_f;;
		ls)	ls_f "$more";;
		cd)	cd_f "$more";;
		cat)	cat_f "$more";;
		rm)	rm_f "$more";;
		touch)	touch_f "$more";;
		mkdir)	mkdir_f "$more";;
		"") ;; # Manage empty entry 
		exit|quit)
			echo "- Exiting shell vsh -" 
			exit;;
		*)	echo "$cmd: command not found";;
		esac
	done
fi
