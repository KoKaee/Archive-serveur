# Archive-serveur

# vsh (Virtual Shell) & Custom Archive Server

**vsh (Virtual Shell)** is a lightweight and robust client-server architecture developed entirely in **Bash**, designed for remote archive management and exploration. 

Unlike traditional archiving tools, `vsh` implements a complete **Virtual File System (VFS)**. Through the interactive `-browse` mode, you can navigate, read, and dynamically modify the contents of an archive stored on the remote server directly from a virtual command prompt—without ever needing to extract the archive locally.

This project was developed at the **University of Technology of Troyes (UTT)** as part of the *LO14 - Systems Administration* course.

---

## Authors
* **Tom FERRASSE--JAMAUX** : Interactive mode logic (`-browse`), Header parsing, and virtual commands.
* **Amaury DUFRENOT** : Listening server logic, archive creation, extraction, and network transfers (`-create`, `-list`, `-extract`).

---

## Features

### Server Side (`server.sh`)
* **Native Network Listening**: Relies on a single standard dependency: `netcat` (`nc`).
* **Persistent Bidirectional Communication**: Uses a relay mechanism via a named pipe (FIFO) to handle input/output streams asynchronously.
* **Streamlined Protocol Requests**: Full support for `LIST` (list archives), `GET` (download), and `PUT` (upload) requests.

### Client Side (`vsh.sh`)
* **`-list` Mode**: Retrieves and displays the list of archives available on the remote server.
* **`-create` Mode**: Recursively traverses a local directory to compile a custom structured archive, then uploads it to the server.
* **`-extract` Mode**: Downloads a remote archive and faithfully reconstructs the local directory tree, restoring executable permissions (`chmod +x`) where necessary.
* **`-browse` Mode (Interactive Mini-Shell)** : Opens a `vsh:>` prompt emulating a Unix environment to manipulate the archive on the fly.

---

## `.vsh` Archive Format Specification

The archive format is optimized for sequential line-by-line processing using POSIX tools (`sed`, `awk`, `grep`):

1. **Metadata Line (Line 1)**: Contains index pointers formatted as `Header_Start:Body_Start` (e.g., `2:24`).
2. **The Header (Metadata)**: Organized into directory blocks opened by `directory <path>` and closed by a `@` symbol. Each file entry is written in a long format: `[name] [permissions] [size] [body_offset] [line_count]`.
3. **The Body (Raw Data)**: The concatenated text content of all files within the archive.

---

## 🛠️ Virtual Shell Commands (`-browse`)

Once inside the interactive mode, the following Unix-like commands are virtually simulated:

| Command | Options | Description |
| :--- | :--- | :--- |
| `pwd` | *None* | Prints the absolute path of the current virtual directory. |
| `ls` | `-a`, `-l`, `-al` | Lists files. Supports detailed format, hidden files, and appends visual indicators (`\` for directories, `*` for executables)[cite: 1, 4]. |
| `cd` | `[path]`, `..`, `\` | Changes the position pointer. Supports relative paths, absolute paths, and parent directory navigation. |
| `cat` | `[file]` | Extracts and displays the lines from the *Body* associated with the targeted file. |
| `touch` | `[file]` | Inserts a new empty file entry into the *Header*. |
| `mkdir` | `-p` | Creates a directory. The `-p` option allows for the recursive creation of complex path structures. |
| `rm` | `[target]` | Deletes a file or directory recursively via `sed` range addressing with dynamic global offset recalculation. |

 **Note on Persistence**: If any modifications (`touch`, `mkdir`, `rm`) are made during the session, the archive is automatically recompiled, synchronized, and sent back to the server via a `PUT` request upon closing the shell (`exit`).

---

## Usage

### 1. Start the Server
On the remote machine (or locally for testing), start the server script by specifying a listening port:
```bash
./server.sh 8080
