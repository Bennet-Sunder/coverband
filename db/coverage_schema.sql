-- Simplified MySQL Schema for Test Coverage Data
-- Compatible with older MySQL versions

CREATE DATABASE IF NOT EXISTS itildesk1;
USE itildesk1;

CREATE TABLE test_coverage (
    id BIGINT PRIMARY KEY AUTO_INCREMENT,
    test_case_id VARCHAR(255) NOT NULL,
    request_details VARCHAR(2000) NOT NULL,
    file_paths JSON NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    
    INDEX idx_test_case_id (test_case_id),
    INDEX idx_request_details (request_details(255)),
    UNIQUE KEY unique_test_request (test_case_id, request_details(255))
) ENGINE=InnoDB;