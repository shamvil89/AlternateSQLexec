// Initialize ACE editor
let editor;

// Cache for database objects
let dbObjectsCache = {
    databases: { items: [], lastUpdate: null },
    tables: { items: [], lastUpdate: null },
    views: { items: [], lastUpdate: null },
    columns: { items: [], lastUpdate: null, tableMap: {} }
};

let currentDatabase = null;

// Function to fetch database objects
async function fetchDatabaseObjects(serverName, objectType, context = null) {
    try {
        console.log(`Fetching ${objectType} from ${serverName}`, context);
        
        const response = await fetch('/api/database-objects', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName,
                objectType,
                context: {
                    ...context,
                    database: currentDatabase
                }
            })
        });

        const data = await response.json();
        
        if (data.error) {
            console.error(`Error fetching ${objectType}:`, data.error);
            showMessage(`Error fetching ${objectType}: ${data.error}`, true);
            return [];
        }
        
        return data.objects || [];
    } catch (error) {
        console.error(`Error fetching ${objectType}:`, error);
        showMessage(`Failed to fetch ${objectType}: ${error.message}`, true);
        return [];
    }
}

// Function to check if cache needs refresh
function needsRefresh(cacheEntry, maxAge = 5 * 60 * 1000) { // 5 minutes default
    return !cacheEntry.lastUpdate || (Date.now() - cacheEntry.lastUpdate) > maxAge;
}

// Function to get completion items based on context
async function getCompletionItems(editor, prefix, context) {
    const serverName = document.getElementById('serverName').value;
    if (!serverName) return [];

    const completions = [];
    const line = editor.session.getLine(context.row);
    const beforeCursor = line.slice(0, context.column);

    try {
        // Always check databases first if not cached
        if (needsRefresh(dbObjectsCache.databases)) {
            dbObjectsCache.databases.items = await fetchDatabaseObjects(serverName, 'databases');
            dbObjectsCache.databases.lastUpdate = Date.now();
            
            // Update database dropdown if it exists
            updateDatabaseDropdown(dbObjectsCache.databases.items);
        }

        // Determine context
        const isUseStatement = /^\s*USE\s+/i.test(beforeCursor);
        const isAfterFrom = /\bFROM\s+([^\s;]*)$/i.test(beforeCursor);
        const isAfterJoin = /\b(JOIN)\s+([^\s;]*)$/i.test(beforeCursor);
        const isAfterDot = /\.[\w-]*$/.test(beforeCursor);
        const isInSelect = /\bSELECT\b/i.test(beforeCursor) && !/\bFROM\b/i.test(beforeCursor);

        // Handle USE statement completion
        if (isUseStatement) {
            completions.push(...dbObjectsCache.databases.items.map(db => ({
                caption: db.name,
                value: db.name,
                meta: 'database',
                score: 1000
            })));
            return completions;
        }

        // Load tables and views if needed after FROM or JOIN
        if (isAfterFrom || isAfterJoin) {
            if (needsRefresh(dbObjectsCache.tables)) {
                dbObjectsCache.tables.items = await fetchDatabaseObjects(serverName, 'tables');
                dbObjectsCache.tables.lastUpdate = Date.now();
            }
            if (needsRefresh(dbObjectsCache.views)) {
                dbObjectsCache.views.items = await fetchDatabaseObjects(serverName, 'views');
                dbObjectsCache.views.lastUpdate = Date.now();
            }
            
            // Add tables and views to completions
            completions.push(...dbObjectsCache.tables.items.map(t => ({
                caption: `${t.schema}.${t.name}`,
                value: `${t.schema}.${t.name}`,
                meta: 'table',
                score: 1000
            })));
            completions.push(...dbObjectsCache.views.items.map(v => ({
                caption: `${v.schema}.${v.name}`,
                value: `${v.schema}.${v.name}`,
                meta: 'view',
                score: 900
            })));
        }
        
        // Load columns if needed after dot or in SELECT
        if (isAfterDot || isInSelect) {
            const tableMatch = beforeCursor.match(/([a-zA-Z0-9_]+)\.$/);
            if (tableMatch || isInSelect) {
                const tableName = tableMatch ? tableMatch[1] : null;
                
                // Only fetch columns for specific table if we know it
                if (tableName && !dbObjectsCache.columns.tableMap[tableName]) {
                    const columns = await fetchDatabaseObjects(serverName, 'columns', { table: tableName });
                    dbObjectsCache.columns.tableMap[tableName] = columns;
                    dbObjectsCache.columns.lastUpdate = Date.now();
                }
                // Fetch all columns if in general SELECT context
                else if (!tableName && needsRefresh(dbObjectsCache.columns)) {
                    dbObjectsCache.columns.items = await fetchDatabaseObjects(serverName, 'columns');
                    dbObjectsCache.columns.lastUpdate = Date.now();
                }
                
                // Add relevant columns to completions
                const relevantColumns = tableName 
                    ? (dbObjectsCache.columns.tableMap[tableName] || [])
                    : dbObjectsCache.columns.items;
                
                completions.push(...relevantColumns.map(col => ({
                    caption: col.name,
                    value: col.name,
                    meta: `${col.dataType} (${col.schema}.${col.table})`,
                    score: 700
                })));
            }
        }

        // Add SQL keywords with appropriate context
        const keywords = getContextualKeywords(beforeCursor);
        completions.push(...keywords.map(keyword => ({
            caption: keyword,
            value: keyword,
            meta: 'keyword',
            score: 500
        })));

        return completions;
    } catch (error) {
        console.error('Error getting completions:', error);
        showMessage(`Error loading suggestions: ${error.message}`, true);
        return [];
    }
}

// Function to update database dropdown
function updateDatabaseDropdown(databases) {
    const dbSelect = document.getElementById('databaseSelect');
    if (!dbSelect) {
        // Create database select if it doesn't exist
        const container = document.querySelector('.sql-editor');
        const select = document.createElement('select');
        select.id = 'databaseSelect';
        select.className = 'form-select mb-2';
        container.insertBefore(select, container.firstChild);
        
        // Add change event listener
        select.addEventListener('change', function() {
            currentDatabase = this.value;
            // Clear cache for database-specific objects
            dbObjectsCache.tables.items = [];
            dbObjectsCache.tables.lastUpdate = null;
            dbObjectsCache.views.items = [];
            dbObjectsCache.views.lastUpdate = null;
            dbObjectsCache.columns.items = [];
            dbObjectsCache.columns.lastUpdate = null;
            dbObjectsCache.columns.tableMap = {};
            
            showMessage(`Switched to database: ${currentDatabase}`);
        });
    }
    
    // Update options
    dbSelect.innerHTML = databases.map(db => 
        `<option value="${db.name}" ${db.isCurrentDb ? 'selected' : ''}>${db.name}</option>`
    ).join('');
    
    // Set current database
    currentDatabase = dbSelect.value;
}

// Function to get contextual keywords
function getContextualKeywords(beforeCursor) {
    const defaultKeywords = ['SELECT', 'FROM', 'WHERE', 'GROUP BY', 'ORDER BY', 'HAVING'];
    const afterSelectKeywords = ['DISTINCT', 'TOP', '*'];
    const afterFromKeywords = ['JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'INNER JOIN', 'CROSS JOIN'];
    const whereKeywords = ['AND', 'OR', 'NOT', 'IN', 'EXISTS', 'BETWEEN', 'LIKE', 'IS NULL', 'IS NOT NULL'];
    
    if (/\bWHERE\b/i.test(beforeCursor)) {
        return whereKeywords;
    } else if (/\bFROM\b/i.test(beforeCursor)) {
        return afterFromKeywords;
    } else if (/\bSELECT\b/i.test(beforeCursor)) {
        return afterSelectKeywords;
    }
    return defaultKeywords;
}

// Custom completer for SQL objects
const sqlCompleter = {
    getCompletions: function(editor, session, pos, prefix, callback) {
        const context = {
            row: pos.row,
            column: pos.column,
            line: session.getLine(pos.row)
        };
        
        getCompletionItems(editor, prefix, context).then(completions => {
            callback(null, completions);
        }).catch(error => {
            console.error('Error in completion:', error);
            callback(null, []);
        });
    }
};

// Initialize ACE editor
document.addEventListener('DOMContentLoaded', function() {
    // Initialize ACE editor
    editor = ace.edit("editor");
    editor.setTheme("ace/theme/sqlserver");
    editor.session.setMode("ace/mode/sql");
    editor.setOptions({
        fontSize: "12pt",
        showPrintMargin: false,
        showGutter: true,
        highlightActiveLine: true,
        wrap: true,
        enableLiveAutocompletion: true,
        enableBasicAutocompletion: true
    });

    // Set custom completer
    editor.completers = [sqlCompleter];

    // Clear the editor content
    editor.setValue("");

    // Add server name input event listener
    const serverNameInput = document.getElementById('serverName');
    serverNameInput.addEventListener('input', function() {
        // Clear cache when server name changes
        dbObjectsCache = {
            databases: { items: [], lastUpdate: null },
            tables: { items: [], lastUpdate: null },
            views: { items: [], lastUpdate: null },
            columns: { items: [], lastUpdate: null, tableMap: {} }
        };
        validateEnvironment();
    });

    // Initialize Bootstrap tabs
    const tabElements = document.querySelectorAll('a[data-bs-toggle="tab"]');
    tabElements.forEach(tab => {
        new bootstrap.Tab(tab);
    });

    // Show results tab by default
    const resultsTab = document.querySelector('a[href="#results"]');
    const tab = new bootstrap.Tab(resultsTab);
    tab.show();

    // Clear message area
    document.getElementById('messageArea').innerHTML = '';
});

// Validate environment and get environment info
async function validateEnvironment() {
    const serverName = document.getElementById('serverName').value;
    const environmentInfo = document.getElementById('environmentInfo');
    const environmentWarning = document.getElementById('environmentWarning');
    const body = document.body;
    
    if (!serverName) {
        environmentInfo.textContent = '';
        environmentWarning.classList.add('d-none');
        body.style.backgroundColor = '';
        return;
    }

    try {
        const response = await fetch('/api/validate-environment', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName
            })
        });

        const data = await response.json();
        
        if (data.error) {
            environmentInfo.textContent = `Error: ${data.error}`;
            environmentInfo.className = 'form-text text-danger';
            environmentWarning.classList.add('d-none');
            body.style.backgroundColor = '';
            return;
        }

        if (data.environment) {
            environmentInfo.textContent = `Environment: ${data.environment}`;
            environmentInfo.className = 'form-text text-info';

            if (data.environment.toUpperCase() === 'PROD') {
                environmentWarning.classList.remove('d-none');
                body.style.backgroundColor = '#ffebee'; // Light red background
            } else {
                environmentWarning.classList.add('d-none');
                body.style.backgroundColor = '';
            }
        } else {
            environmentInfo.textContent = 'Server not found in inventory';
            environmentInfo.className = 'form-text text-warning';
            environmentWarning.classList.add('d-none');
            body.style.backgroundColor = '';
        }
    } catch (error) {
        environmentInfo.textContent = `Error: ${error.message}`;
        environmentInfo.className = 'form-text text-danger';
        environmentWarning.classList.add('d-none');
        body.style.backgroundColor = '';
    }
}

// Validation wrapper functions
async function validateAndExecute() {
    const serverName = document.getElementById('serverName').value;
    const environmentInfo = document.getElementById('environmentInfo');
    
    try {
        const response = await fetch('/api/validate-environment', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName
            })
        });

        const data = await response.json();
        
        if (data.environment && data.environment.toUpperCase() === 'PROD') {
            showMessage('Execution blocked: Production instance detected', true);
            return;
        }

        executeQuery();
    } catch (error) {
        showMessage(`Error: ${error.message}`, true);
    }
}

async function validateAndParse() {
    const serverName = document.getElementById('serverName').value;
    
    try {
        const response = await fetch('/api/validate-environment', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName
            })
        });

        const data = await response.json();
        
        if (data.environment && data.environment.toUpperCase() === 'PROD') {
            showMessage('Parse blocked: Production instance detected', true);
            return;
        }

        parseQuery();
    } catch (error) {
        showMessage(`Error: ${error.message}`, true);
    }
}

async function validateAndGetPlan() {
    const serverName = document.getElementById('serverName').value;
    
    try {
        const response = await fetch('/api/validate-environment', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName
            })
        });

        const data = await response.json();
        
        if (data.environment && data.environment.toUpperCase() === 'PROD') {
            showMessage('Execution plan blocked: Production instance detected', true);
            return;
        }

        getExecutionPlan();
    } catch (error) {
        showMessage(`Error: ${error.message}`, true);
    }
}

// Clear previous results and messages
function clearResults() {
    const resultTable = document.getElementById('resultTable');
    const messageArea = document.getElementById('messageArea');
    resultTable.innerHTML = '';
    messageArea.innerHTML = '';
}

// Show messages in the message area
function showMessage(message, isError = false, isPrint = false) {
    const messageArea = document.getElementById('messageArea');
    const timestamp = new Date().toLocaleTimeString();
    const messageClass = isError ? 'error-message' : (isPrint ? 'print-message' : 'success-message');
    messageArea.innerHTML += `<div class="${messageClass}">${timestamp}: ${message}</div>`;
    messageArea.scrollTop = messageArea.scrollHeight;
    
    // Switch to messages tab if there's an error or print message
    if (isError || isPrint) {
        const messagesTab = document.querySelector('a[href="#messages"]');
        bootstrap.Tab.getOrCreateInstance(messagesTab).show();
    }
}

// Execute Query
async function executeQuery() {
    const serverName = document.getElementById('serverName').value;
    const query = editor.getValue();
    
    if (!serverName || !query) {
        showMessage('Please provide both server name and query.', true);
        return;
    }

    // Clear previous results
    clearResults();
    showMessage('Executing query...'); // Debug line
    const resultTable = document.getElementById('resultTable');
    resultTable.innerHTML = '<div class="text-center"><div class="spinner-border" role="status"><span class="visually-hidden">Loading...</span></div></div>';

    try {
        console.log('Sending request to execute query...'); // Debug line
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 30000); // 30 second timeout

        const response = await fetch('/api/execute', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName,
                query,
                action: 'execute'
            }),
            signal: controller.signal
        });

        clearTimeout(timeoutId);
        console.log('Received response from server...'); // Debug line
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const data = await response.json();
        console.log('Parsed response:', data); // Debug line
        
        if (data.error) {
            showMessage(data.error, true);
            resultTable.innerHTML = `<div class="alert alert-danger">${data.error}</div>`;
            return;
        }

        // Display any print messages
        if (data.messages && data.messages.length > 0) {
            data.messages.forEach(msg => showMessage(msg, false, true));
        }

        // Handle empty results case
        if (!data.results || !Array.isArray(data.results) || data.results.length === 0) {
            showMessage('Query executed successfully but returned no results.');
            resultTable.innerHTML = '<div class="alert alert-info">Query executed successfully but returned no results.</div>';
            return;
        }

        // Display results
        console.log('Displaying results...', data.results); // Debug line
        displayResults(data.results);
        showMessage(data.message || 'Query executed successfully.');
        
        // Switch to results tab if we have results
        const resultsTab = document.querySelector('a[href="#results"]');
        bootstrap.Tab.getOrCreateInstance(resultsTab).show();

    } catch (error) {
        console.error('Error executing query:', error); // Debug line
        if (error.name === 'AbortError') {
            showMessage('Query timed out after 30 seconds', true);
        } else {
            showMessage(`Error: ${error.message}`, true);
        }
        resultTable.innerHTML = '<div class="alert alert-danger">Query execution failed. Check the Messages tab for details.</div>';
    }
}

// Parse Query
async function parseQuery() {
    const serverName = document.getElementById('serverName').value;
    const query = editor.getValue();
    
    if (!serverName || !query) {
        showMessage('Please provide both server name and query.', true);
        return;
    }

    showMessage('Parsing query...'); // Debug line

    try {
        console.log('Sending parse request...'); // Debug line
        const response = await fetch('/api/execute', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName,
                query,
                action: 'parse'
            })
        });

        console.log('Received parse response...'); // Debug line
        const data = await response.json();
        console.log('Parse result:', data); // Debug line
        
        if (data.error) {
            showMessage(`Syntax error: ${data.error}`, true);
        } else {
            showMessage(data.message || 'Query syntax is valid');
        }
    } catch (error) {
        console.error('Error parsing query:', error); // Debug line
        showMessage(`Error: ${error.message}`, true);
    }
}

// Validate XML string
function isValidExecutionPlan(xmlString) {
    try {
        // Parse XML
        const parser = new DOMParser();
        const xmlDoc = parser.parseFromString(xmlString, "text/xml");
        
        // Check for parse errors
        const parserError = xmlDoc.getElementsByTagName("parsererror");
        if (parserError.length > 0) {
            throw new Error("XML parse error");
        }

        // Check for required execution plan elements
        const isShowPlanXML = xmlDoc.getElementsByTagName("ShowPlanXML").length > 0;
        const hasStmtSimple = xmlDoc.getElementsByTagName("StmtSimple").length > 0 || 
                             xmlDoc.getElementsByTagName("StmtCompound").length > 0;
        
        return isShowPlanXML && hasStmtSimple;
    } catch (e) {
        console.error('XML validation error:', e);
        return false;
    }
}

// Open execution plan in Paste The Plan
function openInPasteThePlan() {
    const planArea = document.getElementById('planArea');
    if (!planArea.textContent) {
        showMessage('No execution plan available to share', true);
        return;
    }

    try {
        // Parse XML to validate it
        const parser = new DOMParser();
        const xmlDoc = parser.parseFromString(planArea.textContent, "text/xml");
        
        // Check for parse errors
        const parserError = xmlDoc.getElementsByTagName("parsererror");
        if (parserError.length > 0) {
            showMessage('Invalid XML format. Please use Parse XML first to validate.', true);
            return;
        }

        // Create a form to post the plan to PasteThePlan
        const form = document.createElement('form');
        form.method = 'POST';
        form.action = 'https://www.brentozar.com/pastetheplan/';
        form.target = '_blank';

        // Add the plan XML as a hidden input
        // Remove any extra whitespace and normalize line endings
        const cleanXml = planArea.textContent
            .trim()
            .replace(/\r\n/g, '\n')
            .replace(/\n\s+/g, '\n')
            .replace(/>\s+</g, '><');

        const input = document.createElement('input');
        input.type = 'hidden';
        input.name = 'sqlplan';
        input.value = cleanXml;

        form.appendChild(input);
        document.body.appendChild(form);
        form.submit();
        document.body.removeChild(form);
        
        showMessage('Opening execution plan in Paste The Plan...');
    } catch (error) {
        showMessage(`Failed to open in Paste The Plan: ${error.message}`, true);
    }
}

// Get Execution Plan
async function getExecutionPlan() {
    const serverName = document.getElementById('serverName').value;
    const query = editor.getValue();
    
    if (!serverName || !query) {
        showMessage('Please provide both server name and query.', true);
        return;
    }

    showMessage('Getting execution plan...'); // Debug line
    const planArea = document.getElementById('planArea');
    planArea.innerHTML = '<div class="text-center"><div class="spinner-border" role="status"><span class="visually-hidden">Loading...</span></div></div>';

    try {
        console.log('Sending execution plan request...'); // Debug line
        const response = await fetch('/api/execute', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                serverName,
                query,
                action: 'plan'
            })
        });

        console.log('Received execution plan response...'); // Debug line
        const data = await response.json();
        console.log('Plan result:', data); // Debug line

        // Extract the plan object if it's wrapped in an array
        const result = Array.isArray(data) ? data.find(item => item && typeof item === 'object' && !Array.isArray(item)) : data;
        console.log('Extracted result:', result); // Debug line
        
        if (result && result.error) {
            showMessage(result.error, true);
            planArea.innerHTML = `<div class="alert alert-danger">${result.error}</div>`;
            
            // Disable buttons since we don't have a valid plan
            document.getElementById('copyXmlBtn').disabled = true;
            document.getElementById('pasteThePlanBtn').disabled = true;
            return;
        }

        // Check if we have a plan property in the response
        if (result && result.plan && typeof result.plan === 'string') {
            console.log('Formatting execution plan XML...'); // Debug line
            // Format and display the XML
            const formattedXml = formatXml(result.plan);
            planArea.textContent = formattedXml;
            showMessage(result.message || 'Execution plan generated successfully');
            
            // Enable the buttons since we have a valid plan
            document.getElementById('copyXmlBtn').disabled = false;
            document.getElementById('pasteThePlanBtn').disabled = false;
            
            // Switch to plan tab
            const planTab = document.querySelector('a[href="#plan"]');
            bootstrap.Tab.getOrCreateInstance(planTab).show();
        } else {
            console.log('No plan in response:', result); // Debug line
            showMessage('No execution plan was returned from server', true);
            planArea.innerHTML = '<div class="alert alert-danger">No execution plan was returned from server.</div>';
            
            // Disable buttons since we don't have a valid plan
            document.getElementById('copyXmlBtn').disabled = true;
            document.getElementById('pasteThePlanBtn').disabled = true;
        }

    } catch (error) {
        console.error('Error getting execution plan:', error); // Debug line
        showMessage(`Error: ${error.message}`, true);
        planArea.innerHTML = '<div class="alert alert-danger">Failed to generate execution plan. Check the Messages tab for details.</div>';
        
        // Disable buttons on error
        document.getElementById('copyXmlBtn').disabled = true;
        document.getElementById('pasteThePlanBtn').disabled = true;
    }
}

// Parse and format XML content
function parseAndFormatXml() {
    const planArea = document.getElementById('planArea');
    const xmlContent = planArea.textContent;
    
    if (!xmlContent) {
        showMessage('No XML content to parse', true);
        return;
    }

    try {
        // Parse XML to validate it
        const parser = new DOMParser();
        const xmlDoc = parser.parseFromString(xmlContent, "text/xml");
        
        // Check for parse errors
        const parserError = xmlDoc.getElementsByTagName("parsererror");
        if (parserError.length > 0) {
            throw new Error("Invalid XML format");
        }

        // Format the XML
        const formattedXml = formatXml(xmlContent);
        planArea.textContent = formattedXml;
        showMessage('XML parsed and formatted successfully');
    } catch (error) {
        showMessage(`Failed to parse XML: ${error.message}`, true);
    }
}

// Helper function to format XML with indentation
function formatXml(xml) {
    let formatted = '';
    let indent = '';
    const tab = '    '; // 4 spaces for indentation
    
    // Remove whitespace between tags
    xml = xml.replace(/(>)\s*(<)/g, '$1$2');
    
    xml.split(/>\s*</).forEach(function(node) {
        if (node.match(/^\/\w/)) {
            // Closing tag - decrease indent
            indent = indent.substring(tab.length);
        }
        
        formatted += indent + '<' + node + '>\r\n';
        
        if (node.match(/^<?\w[^>]*[^\/]$/)) {
            // Opening tag - increase indent
            indent += tab;
        }
    });
    
    // Remove first and last line breaks and extra closing bracket
    return formatted.substring(1, formatted.length - 3);
}

// Display results in table format
function displayResults(results) {
    const resultTable = document.getElementById('resultTable');
    
    if (!results || !results.length) {
        resultTable.innerHTML = '<p>No results to display.</p>';
        return;
    }

    console.log('Building results table...', results); // Debug line

    let table = '<table class="table table-striped table-bordered">';
    
    // Headers
    table += '<thead><tr>';
    Object.keys(results[0]).forEach(key => {
        table += `<th>${key}</th>`;
    });
    table += '</tr></thead>';
    
    // Data
    table += '<tbody>';
    results.forEach(row => {
        table += '<tr>';
        Object.values(row).forEach(value => {
            table += `<td>${value === null ? 'NULL' : value}</td>`;
        });
        table += '</tr>';
    });
    table += '</tbody></table>';
    
    resultTable.innerHTML = table;

    // Switch to results tab
    const resultsTab = document.querySelector('a[href="#results"]');
    const tab = new bootstrap.Tab(resultsTab);
    tab.show();
}

// Copy execution plan XML to clipboard
async function copyPlanToClipboard() {
    const planArea = document.getElementById('planArea');
    if (!planArea.textContent) {
        showMessage('No execution plan available to copy', true);
        return;
    }

    try {
        await navigator.clipboard.writeText(planArea.textContent);
        showMessage('Execution plan copied to clipboard');
    } catch (err) {
        showMessage('Failed to copy execution plan: ' + err.message, true);
    }
} 