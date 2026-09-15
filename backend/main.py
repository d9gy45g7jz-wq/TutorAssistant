import os
import json
import re

import httpx

from dotenv import load_dotenv

from fastapi import FastAPI, HTTPException

from fastapi.middleware.cors import CORSMiddleware

from pydantic import BaseModel



# =====================================
# 环境
# =====================================


load_dotenv()



AMAP_KEY = os.getenv(
    "AMAP_KEY",
    ""
)



DEEPSEEK_API_KEY = os.getenv(
    "DEEPSEEK_API_KEY",
    ""
)





# =====================================
# APP
# =====================================


app = FastAPI(

    title="Tutor Assistant"

)





app.add_middleware(


    CORSMiddleware,


    allow_origins=[

        "http://localhost:3000",

        "http://127.0.0.1:3000"

    ],


    allow_credentials=True,


    allow_methods=["*"],


    allow_headers=["*"]

)









# =====================================
# 数据模型
# =====================================



class AIRequest(BaseModel):

    text:str





class AddressRequest(BaseModel):

    address:str





class RouteRequest(BaseModel):

    origin_lng:float

    origin_lat:float

    destination_lng:float

    destination_lat:float










# =====================================
# 工具
# =====================================


def check_ai():


    if not DEEPSEEK_API_KEY:


        raise HTTPException(

            500,

            "没有配置DEEPSEEK_API_KEY"

        )






def check_amap():


    if not AMAP_KEY:


        raise HTTPException(

            500,

            "没有配置AMAP_KEY"

        )






def parse_json(text:str):


    text=text.strip()



    text=re.sub(

        r"```json",

        "",

        text,

        flags=re.I

    )


    text=text.replace(

        "```",

        ""

    )



    start=text.find("{")

    end=text.rfind("}")



    if start!=-1 and end!=-1:


        text=text[start:end+1]



    return json.loads(text)











# =====================================
# 首页
# =====================================


@app.get("/")


async def root():


    return {


        "success":True,


        "message":

        "Tutor Assistant Running"


    }









# =====================================
# AI解析
# =====================================


@app.post("/api/ai/parse")


async def ai_parse(

    request:AIRequest

):


    check_ai()





    prompt="""


你是家教信息解析助手。


请从聊天记录提取信息。


必须返回JSON。


格式：


{

"科目":"",

"学生":"",

"地点":"",

"时间":"",

"课时":"",

"价格":"",

"经验":""

}



规则：


1. 所有字段名称必须中文。


2. 科目必须中文。


例如：

English 返回 英语

Math 返回 数学



3. 地址保持中文。


4. 不确定返回空字符串。


5. 不要输出解释。


只输出JSON。



"""







    payload={


        "model":

        "deepseek-chat",



        "messages":[


            {


                "role":

                "system",


                "content":

                prompt


            },


            {


                "role":

                "user",


                "content":

                request.text


            }


        ],


        "temperature":

        0.1



    }







    headers={


        "Authorization":

        f"Bearer {DEEPSEEK_API_KEY}",



        "Content-Type":

        "application/json"



    }








    async with httpx.AsyncClient(

        timeout=60

    ) as client:


        response=await client.post(


            "https://api.deepseek.com/chat/completions",


            headers=headers,


            json=payload


        )







    if response.status_code != 200:


        raise HTTPException(

            500,

            response.text

        )







    data=response.json()






    content=data["choices"][0]["message"]["content"]






    result=parse_json(

        content

    )








    return {


        "success":True,


        "result":result


    }



# =====================================
# 地址解析
# =====================================


@app.post("/api/geocode")


async def geocode(

    request:AddressRequest

):


    check_amap()






    params={


        "key":

        AMAP_KEY,


        "address":

        request.address,


        "output":

        "json"


    }







    async with httpx.AsyncClient(

        timeout=15

    ) as client:


        res=await client.get(


            "https://restapi.amap.com/v3/geocode/geo",


            params=params


        )







    data=res.json()







    if data.get("status")!="1":


        raise HTTPException(

            400,

            data.get(

                "info",

                "地址解析失败"

            )

        )








    geocode=data.get(

        "geocodes",

        []

    )







    if not geocode:


        raise HTTPException(

            404,

            "没有找到地址"

        )







    location=geocode[0]["location"]






    lng,lat=location.split(",")








    return {


        "success":True,


        "lng":

        float(lng),



        "lat":

        float(lat),



        "formatted_address":

        geocode[0].get(

            "formatted_address",

            request.address

        )



    }












# =====================================
# 高德路线请求
# =====================================



async def amap_route(

    mode,

    origin,

    destination

):


    check_amap()






    if mode=="driving":


        url=(

        "https://restapi.amap.com/v3/direction/driving"

        )




    elif mode=="walking":


        url=(

        "https://restapi.amap.com/v3/direction/walking"

        )




    elif mode=="transit":


        url=(

        "https://restapi.amap.com/v3/direction/transit/integrated"

        )




    else:


        return None









    params={


        "key":

        AMAP_KEY,


        "origin":

        origin,


        "destination":

        destination,


        "output":

        "json"



    }







    if mode=="transit":


        params["city"]="上海"








    async with httpx.AsyncClient(

        timeout=20

    ) as client:


        res=await client.get(


            url,


            params=params


        )








    data=res.json()








    if data.get("status")!="1":


        return None






    return data













# =====================================
# 路线解析
# =====================================


def parse_route(

    mode,

    data

):



    try:



        route=data["route"]






        if mode=="transit":


            item=route["transits"][0]



        else:


            item=route["paths"][0]









        distance=float(

            item.get(

                "distance",

                0

            )

        )








        duration=float(

            item.get(

                "duration",

                0

            )

        )








        return {


            "available":

            True,



            "distance_km":

            round(

                distance/1000,

                2

            ),



            "duration_minutes":

            max(

                1,

                round(

                    duration/60

                )

            )



        }




    except Exception:


        return {


            "available":

            False


        }












# =====================================
# 电动车计算
# =====================================


def calculate_bike_time(

    distance_km

):


    # 城市电动车平均18km/h

    speed=18





    # 加红绿灯等待

    extra=1.2






    minutes=(

        distance_km

        /

        speed

        *

        60

        *

        extra

    )






    return max(

        1,

        round(minutes)

    )












async def get_bicycle(

    origin,

    destination

):


    # 使用驾车距离

    # 更接近真实道路距离


    data=await amap_route(

        "driving",

        origin,

        destination

    )







    if not data:


        return {


            "available":

            False


        }







    route=parse_route(

        "driving",

        data

    )







    if not route["available"]:


        return {


            "available":

            False


        }







    route["duration_minutes"]=calculate_bike_time(

        route["distance_km"]

    )







    return route



# =====================================
# 总路线接口
# =====================================


@app.post("/api/routes")


async def routes(

    request:RouteRequest

):



    origin=(

        f"{request.origin_lng},"

        f"{request.origin_lat}"

    )




    destination=(

        f"{request.destination_lng},"

        f"{request.destination_lat}"

    )








    result={}








    # -------------------------
    # 驾车
    # -------------------------


    driving=await amap_route(

        "driving",

        origin,

        destination

    )



    if driving:


        result["driving"]=parse_route(

            "driving",

            driving

        )


    else:


        result["driving"]={

            "available":False

        }









    # -------------------------
    # 电动车
    # -------------------------


    result["bicycling"]=await get_bicycle(

        origin,

        destination

    )









    # -------------------------
    # 步行
    # -------------------------


    walking=await amap_route(

        "walking",

        origin,

        destination

    )



    if walking:


        result["walking"]=parse_route(

            "walking",

            walking

        )


    else:


        result["walking"]={

            "available":False

        }









    # -------------------------
    # 公交
    # -------------------------


    transit=await amap_route(

        "transit",

        origin,

        destination

    )



    if transit:


        result["transit"]=parse_route(

            "transit",

            transit

        )


    else:


        result["transit"]={

            "available":False

        }









    # =================================
    # 推荐最快
    # =================================



    fastest=None


    best_time=999999





    # 推荐权重

    order=[

        "bicycling",

        "driving",

        "transit",

        "walking"

    ]








    for mode in order:



        item=result.get(

            mode,

            {}

        )



        if item.get(

            "available"

        ):




            time=item.get(

                "duration_minutes",

                999999

            )





            if time < best_time:


                best_time=time


                fastest=mode













    return {


        "success":True,


        "fastest":

        fastest,


        "routes":

        result


    }












# =====================================
# 启动
# =====================================


if __name__=="__main__":


    import uvicorn



    uvicorn.run(


        "main:app",


        host="0.0.0.0",


        port=8000,


       


    )