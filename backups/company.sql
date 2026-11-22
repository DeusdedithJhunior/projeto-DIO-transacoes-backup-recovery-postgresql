--
-- PostgreSQL database dump
--

\restrict 4m0LhypxFuctufYxXVcecICo05OYVE018WZ4U8xHiA6SFNvacfC84gb02ubltEI

-- Dumped from database version 18.6
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: company; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA company;


ALTER SCHEMA company OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: department; Type: TABLE; Schema: company; Owner: postgres
--

CREATE TABLE company.department (
    dnumber integer NOT NULL,
    dname character varying(25) NOT NULL,
    mgr_ssn character(9) NOT NULL,
    mgr_start_date date
);


ALTER TABLE company.department OWNER TO postgres;

--
-- Name: dependent; Type: TABLE; Schema: company; Owner: postgres
--

CREATE TABLE company.dependent (
    essn character(9) NOT NULL,
    dependent_name character varying(15) NOT NULL,
    sex character(1),
    bdate date,
    relationship character varying(8),
    CONSTRAINT dependent_sex_check CHECK ((sex = ANY (ARRAY['M'::bpchar, 'F'::bpchar])))
);


ALTER TABLE company.dependent OWNER TO postgres;

--
-- Name: dept_locations; Type: TABLE; Schema: company; Owner: postgres
--

CREATE TABLE company.dept_locations (
    dnumber integer NOT NULL,
    dlocation character varying(30) NOT NULL
);


ALTER TABLE company.dept_locations OWNER TO postgres;

--
-- Name: employee; Type: TABLE; Schema: company; Owner: postgres
--

CREATE TABLE company.employee (
    ssn character(9) NOT NULL,
    fname character varying(15) NOT NULL,
    minit character(1),
    lname character varying(15) NOT NULL,
    bdate date,
    address character varying(50),
    sex character(1),
    salary numeric(10,2),
    super_ssn character(9),
    dno integer DEFAULT 1 NOT NULL,
    CONSTRAINT employee_salary_check CHECK ((salary > (0)::numeric)),
    CONSTRAINT employee_sex_check CHECK ((sex = ANY (ARRAY['M'::bpchar, 'F'::bpchar])))
);


ALTER TABLE company.employee OWNER TO postgres;

--
-- Name: project; Type: TABLE; Schema: company; Owner: postgres
--

CREATE TABLE company.project (
    pnumber integer NOT NULL,
    pname character varying(25) NOT NULL,
    plocation character varying(30),
    dnum integer NOT NULL
);


ALTER TABLE company.project OWNER TO postgres;

--
-- Name: works_on; Type: TABLE; Schema: company; Owner: postgres
--

CREATE TABLE company.works_on (
    essn character(9) NOT NULL,
    pno integer NOT NULL,
    hours numeric(4,1),
    CONSTRAINT works_on_hours_check CHECK ((hours >= (0)::numeric))
);


ALTER TABLE company.works_on OWNER TO postgres;

--
-- Data for Name: department; Type: TABLE DATA; Schema: company; Owner: postgres
--

COPY company.department (dnumber, dname, mgr_ssn, mgr_start_date) FROM stdin;
1	Headquarters	888665555	1981-06-19
4	Administration	987654321	1995-01-01
5	Research	333445555	1988-05-22
6	Marketing	111222333	2015-03-01
\.


--
-- Data for Name: dependent; Type: TABLE DATA; Schema: company; Owner: postgres
--

COPY company.dependent (essn, dependent_name, sex, bdate, relationship) FROM stdin;
333445555	Alice	F	1986-04-05	Daughter
333445555	Theodore	M	1983-10-25	Son
333445555	Joy	F	1958-05-03	Spouse
987654321	Abner	M	1942-02-28	Spouse
123456789	Michael	M	1988-01-04	Son
123456789	Alice	F	1988-12-30	Daughter
123456789	Elizabeth	F	1967-05-05	Spouse
\.


--
-- Data for Name: dept_locations; Type: TABLE DATA; Schema: company; Owner: postgres
--

COPY company.dept_locations (dnumber, dlocation) FROM stdin;
1	Houston
4	Stafford
5	Bellaire
5	Sugarland
5	Houston
6	Austin
6	Houston
\.


--
-- Data for Name: employee; Type: TABLE DATA; Schema: company; Owner: postgres
--

COPY company.employee (ssn, fname, minit, lname, bdate, address, sex, salary, super_ssn, dno) FROM stdin;
888665555	James	E	Borg	1937-11-10	450 Stone, Houston, TX	M	55000.00	\N	1
333445555	Franklin	T	Wong	1955-12-08	638 Voss, Houston, TX	M	40000.00	888665555	5
987654321	Jennifer	S	Wallace	1941-06-20	291 Berry, Bellaire, TX	F	43000.00	888665555	4
123456789	John	B	Smith	1965-01-09	731 Fondren, Houston, TX	M	30000.00	333445555	5
999887777	Alicia	J	Zelaya	1968-01-19	3321 Castle, Spring, TX	F	25000.00	987654321	4
666884444	Ramesh	K	Narayan	1962-09-15	975 Fire Oak, Humble, TX	M	38000.00	333445555	5
453453453	Joyce	A	English	1972-07-31	5631 Rice, Houston, TX	F	25000.00	333445555	5
987987987	Ahmad	V	Jabbar	1969-03-29	980 Dallas, Houston, TX	M	25000.00	987654321	4
111222333	Laura	M	Costa	1985-04-12	120 Main, Austin, TX	F	47000.00	888665555	6
444555666	Pedro	H	Alves	1990-08-23	87 Lamar, Austin, TX	M	32000.00	111222333	6
777888999	Marina	S	Rocha	1993-02-05	45 Congress, Austin, TX	F	29000.00	111222333	6
222333444	Carlos	R	Lima	1988-11-30	310 Westheimer, Houston, TX	M	36000.00	333445555	5
\.


--
-- Data for Name: project; Type: TABLE DATA; Schema: company; Owner: postgres
--

COPY company.project (pnumber, pname, plocation, dnum) FROM stdin;
1	ProductX	Bellaire	5
2	ProductY	Sugarland	5
3	ProductZ	Houston	5
10	Computerization	Stafford	4
20	Reorganization	Houston	1
30	Newbenefits	Stafford	4
40	BrandLaunch	Austin	6
\.


--
-- Data for Name: works_on; Type: TABLE DATA; Schema: company; Owner: postgres
--

COPY company.works_on (essn, pno, hours) FROM stdin;
123456789	1	32.5
123456789	2	7.5
666884444	3	40.0
453453453	1	20.0
453453453	2	20.0
333445555	2	10.0
333445555	3	10.0
333445555	10	10.0
333445555	20	10.0
999887777	30	30.0
999887777	10	10.0
987987987	10	35.0
987987987	30	5.0
987654321	30	20.0
987654321	20	15.0
888665555	20	\N
111222333	40	20.0
444555666	40	40.0
777888999	40	30.0
222333444	3	25.0
\.


--
-- Name: department department_dname_key; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.department
    ADD CONSTRAINT department_dname_key UNIQUE (dname);


--
-- Name: department department_pkey; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.department
    ADD CONSTRAINT department_pkey PRIMARY KEY (dnumber);


--
-- Name: employee employee_pkey; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.employee
    ADD CONSTRAINT employee_pkey PRIMARY KEY (ssn);


--
-- Name: dependent pk_dependent; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.dependent
    ADD CONSTRAINT pk_dependent PRIMARY KEY (essn, dependent_name);


--
-- Name: dept_locations pk_dept_locations; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.dept_locations
    ADD CONSTRAINT pk_dept_locations PRIMARY KEY (dnumber, dlocation);


--
-- Name: works_on pk_works_on; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.works_on
    ADD CONSTRAINT pk_works_on PRIMARY KEY (essn, pno);


--
-- Name: project project_pkey; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.project
    ADD CONSTRAINT project_pkey PRIMARY KEY (pnumber);


--
-- Name: project project_pname_key; Type: CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.project
    ADD CONSTRAINT project_pname_key UNIQUE (pname);


--
-- Name: department fk_department_manager; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.department
    ADD CONSTRAINT fk_department_manager FOREIGN KEY (mgr_ssn) REFERENCES company.employee(ssn) ON UPDATE CASCADE;


--
-- Name: dependent fk_dependent_employee; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.dependent
    ADD CONSTRAINT fk_dependent_employee FOREIGN KEY (essn) REFERENCES company.employee(ssn) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: dept_locations fk_dept_locations_department; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.dept_locations
    ADD CONSTRAINT fk_dept_locations_department FOREIGN KEY (dnumber) REFERENCES company.department(dnumber) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: employee fk_employee_department; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.employee
    ADD CONSTRAINT fk_employee_department FOREIGN KEY (dno) REFERENCES company.department(dnumber) ON UPDATE CASCADE;


--
-- Name: employee fk_employee_supervisor; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.employee
    ADD CONSTRAINT fk_employee_supervisor FOREIGN KEY (super_ssn) REFERENCES company.employee(ssn) ON UPDATE CASCADE ON DELETE SET NULL;


--
-- Name: project fk_project_department; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.project
    ADD CONSTRAINT fk_project_department FOREIGN KEY (dnum) REFERENCES company.department(dnumber) ON UPDATE CASCADE;


--
-- Name: works_on fk_works_on_employee; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.works_on
    ADD CONSTRAINT fk_works_on_employee FOREIGN KEY (essn) REFERENCES company.employee(ssn) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: works_on fk_works_on_project; Type: FK CONSTRAINT; Schema: company; Owner: postgres
--

ALTER TABLE ONLY company.works_on
    ADD CONSTRAINT fk_works_on_project FOREIGN KEY (pno) REFERENCES company.project(pnumber) ON UPDATE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 4m0LhypxFuctufYxXVcecICo05OYVE018WZ4U8xHiA6SFNvacfC84gb02ubltEI

