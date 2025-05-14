# SQL Server Database Management Solution

A comprehensive PowerShell-based solution for managing SQL Server databases with support for both Windows and SQL Authentication.

## Features

- Flexible authentication support (Windows & SQL Authentication)
- Database backup and restore operations
- Secure credential handling
- Comprehensive error handling and logging
- Web-based interface for database operations
- Support for encrypted connections
- Database inventory management

## Requirements

- PowerShell 5.1 or higher
- SQL Server Management Objects (SMO)
- SQL Server PowerShell module

## Installation

1. Clone this repository
2. Ensure you have the required PowerShell modules installed:
   ```powershell
   Install-Module -Name SqlServer
   ```

## Usage

1. Run the server script:
   ```powershell
   .\server.ps1
   ```
2. Access the web interface at `http://localhost:8080` (or the port shown in console)
3. Follow the prompts for authentication and database selection

## Security Features

- Support for both Windows and SQL Authentication
- Automatic encryption fallback for secure connections
- Secure credential handling
- No storage of sensitive information
- TLS/SSL support

## Error Handling

- Comprehensive error logging
- Fallback mechanisms for connection issues
- User-friendly error messages
- Connection timeout handling

## Contributing

1. Fork the repository
2. Create your feature branch
3. Commit your changes
4. Push to the branch
5. Create a new Pull Request

## License

MIT License - See LICENSE file for details 