#!/usr/bin/env python3
"""
Migration script to load assessment questions from Excel files into the database.
This loads the GDPR questions as a baseline before POPIA content development.

Usage: This script should be run via Docker exec to connect to the staging database:
docker exec -i securepath-staging-db-1 psql -U supabase_admin -d postgres < <(python3 load_questions_from_excel.py)
"""

import openpyxl
import psycopg2
import os
import sys
from datetime import datetime
from typing import List, Dict, Any

# Database connection settings (will be overridden by environment if available)
DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "postgres")
DB_USER = os.environ.get("DB_USER", "supabase_admin")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

# Excel files path
EXCEL_DIR = "/docs/assessment-sheets"  # Path within Docker container

def get_db_connection():
    """Create database connection"""
    return psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        database=DB_NAME,
        user=DB_USER,
        password=DB_PASSWORD
    )

def load_section_xlsx(filepath: str, section_id: int) -> List[Dict[str, Any]]:
    """Parse one audit XLSX and return list of question dictionaries."""
    if not os.path.exists(filepath):
        print(f"Warning: File not found: {filepath}")
        return []
    
    wb = openpyxl.load_workbook(filepath, data_only=True)
    ws = wb.active
    
    questions = []
    current_subsection = ""
    q_number = 0
    
    for row in ws.iter_rows(min_row=6, values_only=True):
        # Detect subsection headers (col A empty, col B has heading text, no ISO ref)
        num_val = str(row[0]).strip() if row[0] else ""
        q_val = str(row[1]).strip() if row[1] else ""
        iso_val = str(row[4]).strip() if len(row) > 4 and row[4] else ""
        
        if not num_val and q_val and not iso_val:
            current_subsection = q_val
            continue
        
        try:
            num = int(float(num_val))
            q_number += 1
            
            questions.append({
                'section_id': section_id,
                'section_name': f"Section {section_id}",
                'subsection': current_subsection,
                'question_number': num,
                'question': str(row[1]) if len(row) > 1 else "",
                'why_matters': str(row[2]) if len(row) > 2 else "",
                'regulatory_ref': str(row[3]) if len(row) > 3 else "",
                'risk': str(row[6]) if len(row) > 6 else "",
                'evidence_req': str(row[8]) if len(row) > 8 else "",
                'remediation': str(row[9]) if len(row) > 9 else "",
            })
        except (ValueError, TypeError):
            continue
    
    return questions

def load_all_questions() -> List[Dict[str, Any]]:
    """Load questions from all 6 Excel files."""
    all_questions = []
    
    for section_id in range(1, 7):
        filepath = os.path.join(EXCEL_DIR, f"Audit_GDPR_DUAA_ISO27701_Section_{section_id}.xlsx")
        questions = load_section_xlsx(filepath, section_id)
        all_questions.extend(questions)
        print(f"Loaded {len(questions)} questions from Section {section_id}")
    
    return all_questions

def insert_questions(conn, questions: List[Dict[str, Any]]) -> None:
    """Insert questions into the database."""
    cursor = conn.cursor()
    
    for q in questions:
        uid = f"S{q['section_id']}_Q{q['question_number']}"
        
        cursor.execute("""
            INSERT INTO public.assessment_questions 
            (framework, section_id, section_name, subsection, question_number,
             question, why_matters, regulatory_ref, risk, evidence_req, remediation, uid)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (uid) DO NOTHING
        """, (
            'gdpr',  # Will be replaced with POPIA in Phase 4
            q['section_id'],
            q['section_name'],
            q['subsection'],
            q['question_number'],
            q['question'],
            q['why_matters'],
            q['regulatory_ref'],
            q['risk'],
            q['evidence_req'],
            q['remediation'],
            uid
        ))
    
    conn.commit()
    print(f"Inserted {len(questions)} questions into database")

def verify_questions(conn) -> None:
    """Verify questions were loaded correctly."""
    cursor = conn.cursor()
    
    # Count total questions
    cursor.execute("SELECT COUNT(*) FROM public.assessment_questions WHERE framework = 'gdpr'")
    count = cursor.fetchone()[0]
    print(f"Total GDPR questions in database: {count}")
    
    # Count by section
    cursor.execute("""
        SELECT section_id, COUNT(*) 
        FROM public.assessment_questions 
        WHERE framework = 'gdpr'
        GROUP BY section_id 
        ORDER BY section_id
    """)
    print("\nQuestions by section:")
    for row in cursor.fetchall():
        print(f"  Section {row[0]}: {row[1]} questions")
    
    # Sample questions
    cursor.execute("""
        SELECT section_id, question_number, question, risk 
        FROM public.assessment_questions 
        WHERE framework = 'gdpr'
        ORDER BY section_id, question_number
        LIMIT 3
    """)
    print("\nSample questions:")
    for row in cursor.fetchall():
        print(f"  S{row[0]}_Q{row[1]}: {row[2][:60]}... (Risk: {row[3]})")

def main():
    """Main migration function."""
    print("Starting assessment questions migration...")
    print(f"Excel directory: {EXCEL_DIR}")
    
    # Check if directory exists
    if not os.path.exists(EXCEL_DIR):
        print(f"Error: Excel directory not found: {EXCEL_DIR}")
        sys.exit(1)
    
    # Load questions from Excel
    print("\nLoading questions from Excel files...")
    questions = load_all_questions()
    print(f"Total questions loaded: {len(questions)}")
    
    if len(questions) == 0:
        print("Error: No questions loaded from Excel files")
        sys.exit(1)
    
    # Connect to database
    print("\nConnecting to database...")
    try:
        conn = get_db_connection()
        print("Database connection established")
    except Exception as e:
        print(f"Error connecting to database: {e}")
        sys.exit(1)
    
    # Insert questions
    print("\nInserting questions into database...")
    try:
        insert_questions(conn, questions)
        print("Questions inserted successfully")
    except Exception as e:
        print(f"Error inserting questions: {e}")
        conn.rollback()
        sys.exit(1)
    
    # Verify
    print("\nVerifying questions...")
    try:
        verify_questions(conn)
    except Exception as e:
        print(f"Error verifying questions: {e}")
        sys.exit(1)
    
    # Cleanup
    conn.close()
    
    print("\nMigration completed successfully!")

if __name__ == "__main__":
    main()