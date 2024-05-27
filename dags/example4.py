from pendulum import datetime

from airflow.decorators import dag 

from airflow import DAG
from cegid_sftp.hooks.sftp import SFTPHook
from airflow.decorators import task ,task_group
from airflow.models.baseoperator import chain
from io import BytesIO
import pandas as pd
import re
import json
from airflow.providers.microsoft.mssql.hooks.mssql import MsSqlHook
from airflow.providers.common.sql.operators.sql import SQLExecuteQueryOperator, SQLTableCheckOperator
from airflow.providers.common.sql.hooks.sql import DbApiHook , fetch_all_handler
import logging






default_args = {
    'owner': 'airflow',
    'depends_on_past': False,
    'start_date': datetime(2023, 1, 1),
    'email_on_failure': False,
    'email_on_retry': False,
    'retries': 1,
}


@dag(
    start_date=datetime(2023, 1, 1),
    schedule=None,
    default_args={"retries": 2, "sample_conn_id": "test"},
    tags=["AIH", "transactional"],
)
def purshaseOrderProposalV2():

    """
    ### Sample DAG

    Showcases the sample provider package's operator and sensor.

    To run this example, create a Sample connection with:
    - id: sample_default
    - type: sample
    - host: https://www.httpbin.org
    """

    @task(task_id = "get_files_from_sftp")
    def task_get_files_from_sftp():
        sftp_hook = SFTPHook(ssh_conn_id="cegid_sftp")

        # Define your regex expression to match the files you want to download
        downloaded_files = sftp_hook.download_files_matching_regex("get" , r"PurchaseOrderProposalLocal.*?\.csv")
        logging.info(downloaded_files)
        dfs_downloaded = []
        for file in downloaded_files:
            logging.info(file)
            print(file)

            df = pd.read_csv(file["memory_object"],sep=';')
            df = df.drop(columns=['Status'])

            
            dfs_downloaded.append({"dataframe" : df , "filename" : file["filename"]})

        # # Return the dictionary containing file contents
        return dfs_downloaded

    @task_group(group_id="validate_dfs")
    def validate_dfs(downloaded_files):

        @task(task_id="load_expectation_suite")
        def load_schema():
            # Load the expectation suite from JSON file
            with open('/home/chames/airflow/schema/schema.json', 'r') as file:
                expectation_suite = json.load(file)
            return expectation_suite


        @task(task_id="validation")
        def validation(downloaded_files , schema):
            import jsonschema
            from jsonschema import Draft202012Validator 
            validation_result = []

            for df in downloaded_files:
                    
            
                    validated_records = []
                    invalid_records = []
                
 
                    for row in json.loads(df["dataframe"].to_json(orient='records')):
                    
                            try:
                                jsonschema.validate(instance=row, schema=schema,format_checker=Draft202012Validator.FORMAT_CHECKER)
                                validated_records.append(row)
                            except jsonschema.exceptions.ValidationError as e:
                                invalid_records.append({'row': row, 'errors': str(e.message)})
                
                

                    validation_result.append({"filename" : df["filename"] ,"validated_records" : validated_records, "invalid_records" : invalid_records})
            return validation_result
            


        schema = load_schema()
        validation_output =  validation(downloaded_files,schema)
        schema >> validation_output
        return validation_output


        
    @task_group(group_id="serving_destination")
    def serving_destination(validation_output):
         @task(task_id="connect_to_sql_server")
         def connect_to_sql_server():
              conn = MsSqlHook(mssql_conn_id="ms_sql")
              
              
              print(conn)
              print(conn.test_connection())
              return conn
         @task(task_id="insert_data")
         def insert_to_sql_server(connection , data_to_insert):
              from contextlib import closing
              
              sql_query = ""
              for file in data_to_insert:
       
                    file = file["validated_records"]
                    sql_query = """
                        SELECT * FROM test
                    """
                    inserts=[]
                    print(file)
                    columns = tuple(file[0].keys()) 
                    columns_sql = ', '.join(file[0].keys())
                    for row in file:
                        # Construct the SQL statement with placeholders for values
                        sql = f"INSERT INTO test ({columns_sql}) VALUES ({', '.join(['%s'] * len(columns))});"
                        
                        # Extract values from the row
                        values = tuple(row[column] for column in columns)
                        
                        # Append the SQL statement and values to the list
                        inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values)) ²x    cc                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
                        # inserts.append((sql, values))
             
              with closing(connection.get_conn()) as connect:
                   with closing(connect.cursor()) as cur:
                        print(connection.get_uri())
                        cur.execute("select * from test") 
                        print(cur.fetchall())
              print(inserts)         
              with closing(connection.get_conn()) as connect:
                   with closing(connect.cursor()) as cur:
                        for sql , values in inserts :
                            try:
                                connection._run_command(  
                                     cur , 
                                         sql,
                                         values


                                    )
                            except Exception as e : 
                                print(e)
                        
              
         conn = connect_to_sql_server()
        #  sql_table_check = SQLExecuteQueryOperator(sql="select * from test" ,
        #     conn_id = "ms_sql" , 
        #     task_id = "sql_table_check",
        #     show_return_value_in_logs = True)
         insertion = insert_to_sql_server(conn,validation_output)



         
         return insertion

         

    # Define the task dependencies
    downloaded_files = task_get_files_from_sftp() 
    validate = validate_dfs(downloaded_files)
    serving = serving_destination(validate)

    downloaded_files >> validate >> serving

    
    


purshaseOrderProposalV2()
