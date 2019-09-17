import json
import boto3
import logging
import traceback

logger = logging.getLogger()
logger.setLevel(logging.INFO)

emrclient = boto3.client('emr',region_name='us-east-1')
cfclient = boto3.client('cloudformation',region_name='us-east-1')

def lambda_handler(event, context):
    
    try:
        cf_EMR = False
        sns_record = event['Records'][0]['Sns']
        
        sns_message_json = sns_record['Message']
        print(sns_message_json)
    
        sns_message = json.loads(sns_message_json)
        #sns_trigger = sns_message['Trigger']
        #print(sns_trigger)
        dimensions = sns_message['Trigger']['Dimensions']
        #print(dimensions)
        
        #dimension = dimensions[0]
        #dimension_value = dimension['value']
        #print(dimension_value)
    
        for dimension in dimensions:
            if dimension['name'] == 'JobFlowId':
                dimension_value = dimension['value']
                break
        print(type(dimension_value))
        print(dimension_value)
        
        dimension_value_str = str(dimension_value)
        print(dimension_value_str)
        print(type(dimension_value_str))
        logger.info(dimension_value_str)
        
        ### Get all stacks in create complete status ##
        cf_validstacks = cfclient.list_stacks(StackStatusFilter=['CREATE_COMPLETE'])
        cf_stacknames = []
        cf_clusterid_stacknames = {}
        
        ## Get all Stack resources from the stack name ###
        for stack in cf_validstacks['StackSummaries']:
            cf_stacknames.append(stack['StackName'])
        
        for stackname in cf_stacknames:
            stackresourcesresponse = cfclient.list_stack_resources(StackName=stackname)
            
            for summary in stackresourcesresponse['StackResourceSummaries']:
                jobid_stackres = summary['PhysicalResourceId']
                #print(jobid_stackres)
                #print(type(jobid_stackres))
                
                if jobid_stackres == dimension_value_str:
                    cf_EMR = True
                    cfclient.delete_stack(StackName=stackname)
                    #print('true')
                    
        if not cf_EMR:
            terminateResponse = emrclient.terminate_job_flows(
                JobFlowIds=[
                    dimension_value_str
                ]
            )
            print(terminateResponse)
            
    except Exception as e:
        traceback.print_exc()
        print(e)
    return