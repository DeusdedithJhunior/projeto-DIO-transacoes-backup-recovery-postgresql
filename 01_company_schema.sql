-- =====================================================================
-- 01_company_schema.sql
-- Banco COMPANY (esquema clássico do livro "Sistemas de Banco de Dados",
-- Elmasri & Navathe) criado no schema "company".
-- PostgreSQL 14+
--
-- Atenção: o script recria o schema do zero (DROP ... CASCADE), o que
-- também remove índices e procedures criados pelos scripts 03 e 05.
-- =====================================================================

DROP SCHEMA IF EXISTS company CASCADE;
CREATE SCHEMA company;
SET search_path TO company;

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------

-- Empregados. As FKs de dno (departamento) e super_ssn (supervisor) são
-- adicionadas no final, depois da carga, porque employee e department
-- se referenciam mutuamente (referência circular).
CREATE TABLE employee (
    ssn         CHAR(9)        PRIMARY KEY,
    fname       VARCHAR(15)    NOT NULL,
    minit       CHAR(1),
    lname       VARCHAR(15)    NOT NULL,
    bdate       DATE,
    address     VARCHAR(50),
    sex         CHAR(1)        CHECK (sex IN ('M', 'F')),
    salary      NUMERIC(10,2)  CHECK (salary > 0),
    super_ssn   CHAR(9),
    dno         INT            NOT NULL DEFAULT 1
);

CREATE TABLE department (
    dnumber         INT            PRIMARY KEY,
    dname           VARCHAR(25)    NOT NULL UNIQUE,
    mgr_ssn         CHAR(9)        NOT NULL,
    mgr_start_date  DATE,
    CONSTRAINT fk_department_manager
        FOREIGN KEY (mgr_ssn) REFERENCES employee (ssn)
        ON UPDATE CASCADE
);

CREATE TABLE dept_locations (
    dnumber     INT            NOT NULL,
    dlocation   VARCHAR(30)    NOT NULL,
    CONSTRAINT pk_dept_locations PRIMARY KEY (dnumber, dlocation),
    CONSTRAINT fk_dept_locations_department
        FOREIGN KEY (dnumber) REFERENCES department (dnumber)
        ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE TABLE project (
    pnumber     INT            PRIMARY KEY,
    pname       VARCHAR(25)    NOT NULL UNIQUE,
    plocation   VARCHAR(30),
    dnum        INT            NOT NULL,
    CONSTRAINT fk_project_department
        FOREIGN KEY (dnum) REFERENCES department (dnumber)
        ON UPDATE CASCADE
);

CREATE TABLE works_on (
    essn    CHAR(9)        NOT NULL,
    pno     INT            NOT NULL,
    hours   NUMERIC(4,1)   CHECK (hours >= 0),
    CONSTRAINT pk_works_on PRIMARY KEY (essn, pno),
    CONSTRAINT fk_works_on_employee
        FOREIGN KEY (essn) REFERENCES employee (ssn)
        ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_works_on_project
        FOREIGN KEY (pno) REFERENCES project (pnumber)
        ON UPDATE CASCADE
);

CREATE TABLE dependent (
    essn            CHAR(9)        NOT NULL,
    dependent_name  VARCHAR(15)    NOT NULL,
    sex             CHAR(1)        CHECK (sex IN ('M', 'F')),
    bdate           DATE,
    relationship    VARCHAR(8),
    CONSTRAINT pk_dependent PRIMARY KEY (essn, dependent_name),
    CONSTRAINT fk_dependent_employee
        FOREIGN KEY (essn) REFERENCES employee (ssn)
        ON DELETE CASCADE ON UPDATE CASCADE
);

-- ---------------------------------------------------------------------
-- Dados de exemplo (base do livro + alguns registros extras para que
-- as consultas por departamento e cidade tenham mais variação)
-- ---------------------------------------------------------------------

INSERT INTO employee (ssn, fname, minit, lname, bdate, address, sex, salary, super_ssn, dno) VALUES
    ('888665555', 'James',    'E', 'Borg',     '1937-11-10', '450 Stone, Houston, TX',     'M', 55000, NULL,        1),
    ('333445555', 'Franklin', 'T', 'Wong',     '1955-12-08', '638 Voss, Houston, TX',      'M', 40000, '888665555', 5),
    ('987654321', 'Jennifer', 'S', 'Wallace',  '1941-06-20', '291 Berry, Bellaire, TX',    'F', 43000, '888665555', 4),
    ('123456789', 'John',     'B', 'Smith',    '1965-01-09', '731 Fondren, Houston, TX',   'M', 30000, '333445555', 5),
    ('999887777', 'Alicia',   'J', 'Zelaya',   '1968-01-19', '3321 Castle, Spring, TX',    'F', 25000, '987654321', 4),
    ('666884444', 'Ramesh',   'K', 'Narayan',  '1962-09-15', '975 Fire Oak, Humble, TX',   'M', 38000, '333445555', 5),
    ('453453453', 'Joyce',    'A', 'English',  '1972-07-31', '5631 Rice, Houston, TX',     'F', 25000, '333445555', 5),
    ('987987987', 'Ahmad',    'V', 'Jabbar',   '1969-03-29', '980 Dallas, Houston, TX',    'M', 25000, '987654321', 4),
    -- registros extras (não constam no livro)
    ('111222333', 'Laura',    'M', 'Costa',    '1985-04-12', '120 Main, Austin, TX',       'F', 47000, '888665555', 6),
    ('444555666', 'Pedro',    'H', 'Alves',    '1990-08-23', '87 Lamar, Austin, TX',       'M', 32000, '111222333', 6),
    ('777888999', 'Marina',   'S', 'Rocha',    '1993-02-05', '45 Congress, Austin, TX',    'F', 29000, '111222333', 6),
    ('222333444', 'Carlos',   'R', 'Lima',     '1988-11-30', '310 Westheimer, Houston, TX','M', 36000, '333445555', 5);

INSERT INTO department (dnumber, dname, mgr_ssn, mgr_start_date) VALUES
    (1, 'Headquarters',   '888665555', '1981-06-19'),
    (4, 'Administration', '987654321', '1995-01-01'),
    (5, 'Research',       '333445555', '1988-05-22'),
    (6, 'Marketing',      '111222333', '2015-03-01');

INSERT INTO dept_locations (dnumber, dlocation) VALUES
    (1, 'Houston'),
    (4, 'Stafford'),
    (5, 'Bellaire'),
    (5, 'Sugarland'),
    (5, 'Houston'),
    (6, 'Austin'),
    (6, 'Houston');

INSERT INTO project (pnumber, pname, plocation, dnum) VALUES
    (1,  'ProductX',        'Bellaire',  5),
    (2,  'ProductY',        'Sugarland', 5),
    (3,  'ProductZ',        'Houston',   5),
    (10, 'Computerization', 'Stafford',  4),
    (20, 'Reorganization',  'Houston',   1),
    (30, 'Newbenefits',     'Stafford',  4),
    (40, 'BrandLaunch',     'Austin',    6);

INSERT INTO works_on (essn, pno, hours) VALUES
    ('123456789', 1,  32.5),
    ('123456789', 2,   7.5),
    ('666884444', 3,  40.0),
    ('453453453', 1,  20.0),
    ('453453453', 2,  20.0),
    ('333445555', 2,  10.0),
    ('333445555', 3,  10.0),
    ('333445555', 10, 10.0),
    ('333445555', 20, 10.0),
    ('999887777', 30, 30.0),
    ('999887777', 10, 10.0),
    ('987987987', 10, 35.0),
    ('987987987', 30,  5.0),
    ('987654321', 30, 20.0),
    ('987654321', 20, 15.0),
    ('888665555', 20, NULL),
    ('111222333', 40, 20.0),
    ('444555666', 40, 40.0),
    ('777888999', 40, 30.0),
    ('222333444', 3,  25.0);

INSERT INTO dependent (essn, dependent_name, sex, bdate, relationship) VALUES
    ('333445555', 'Alice',     'F', '1986-04-05', 'Daughter'),
    ('333445555', 'Theodore',  'M', '1983-10-25', 'Son'),
    ('333445555', 'Joy',       'F', '1958-05-03', 'Spouse'),
    ('987654321', 'Abner',     'M', '1942-02-28', 'Spouse'),
    ('123456789', 'Michael',   'M', '1988-01-04', 'Son'),
    ('123456789', 'Alice',     'F', '1988-12-30', 'Daughter'),
    ('123456789', 'Elizabeth', 'F', '1967-05-05', 'Spouse');

-- ---------------------------------------------------------------------
-- FKs adiadas (referência circular employee <-> department e
-- autorreferência do supervisor)
-- ---------------------------------------------------------------------
ALTER TABLE employee
    ADD CONSTRAINT fk_employee_department
        FOREIGN KEY (dno) REFERENCES department (dnumber)
        ON UPDATE CASCADE,
    ADD CONSTRAINT fk_employee_supervisor
        FOREIGN KEY (super_ssn) REFERENCES employee (ssn)
        ON DELETE SET NULL ON UPDATE CASCADE;

-- Conferência rápida da carga
SELECT 'employee' AS tabela, COUNT(*) FROM employee
UNION ALL SELECT 'department',     COUNT(*) FROM department
UNION ALL SELECT 'dept_locations', COUNT(*) FROM dept_locations
UNION ALL SELECT 'project',        COUNT(*) FROM project
UNION ALL SELECT 'works_on',       COUNT(*) FROM works_on
UNION ALL SELECT 'dependent',      COUNT(*) FROM dependent;
