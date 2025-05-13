# SQL Query Executor

A web-based SQL query execution tool with advanced features for SQL Server database management.

## Features

- Web-based SQL query interface
- Support for multiple SQL Server instances
- Environment validation (DEV/PROD)
- Database object IntelliSense
- Query execution with detailed results
- Special handling for RESTORE commands
- Error handling with detailed messages
- Environment-aware execution restrictions

## Prerequisites

- Windows OS
- PowerShell 5.1 or later
- SQL Server Management Objects (SMO)
- SQL Server PowerShell module

## Installation

1. Clone this repository:
```powershell
git clone https://github.com/yourusername/sql-query-executor.git
cd sql-query-executor
```

2. Ensure you have the required PowerShell modules:
```powershell
Install-Module -Name SqlServer -Scope CurrentUser
```

## Usage

1. Start the server:
```powershell
.\server.ps1
```

2. Open your web browser and navigate to:
```
http://localhost:8080
```

3. Enter your SQL Server instance name and start executing queries.

## Security Features

- Production environment protection
- SQL injection prevention
- Proper error handling
- Connection pooling
- Timeout management

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details. 