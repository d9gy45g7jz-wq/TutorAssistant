"use client";


import {

    useState

} from "react";





const API =

"http://127.0.0.1:8000";







const labels:any={


    "科目":

    "科目",



    "学生":

    "学生",



    "地点":

    "地点",



    "时间":

    "上课时间",



    "课时":

    "课时",



    "价格":

    "价格",



    "经验":

    "经验要求"



};









export default function Home(){





    // =========================
    // 输入
    // =========================



    const [chat,setChat]=

    useState("");





    const [myAddress,setMyAddress]=

    useState("");





    const [tutorAddress,setTutorAddress]=

    useState("");









    // =========================
    // 数据
    // =========================



    const [aiData,setAiData]=

    useState<any>(null);





    const [myLocation,setMyLocation]=

    useState<any>(null);





    const [tutorLocation,setTutorLocation]=

    useState<any>(null);





    const [routes,setRoutes]=

    useState<any>(null);









    // =========================
    // 状态
    // =========================



    const [aiLoading,setAiLoading]=

    useState(false);





    const [myLoading,setMyLoading]=

    useState(false);





    const [tutorLoading,setTutorLoading]=

    useState(false);





    const [routeLoading,setRouteLoading]=

    useState(false);





    const [msg,setMsg]=

    useState("");









    // =========================
    // AI解析
    // =========================



    async function parseAI(){



        if(!chat.trim()){


            setMsg(

                "请输入家教聊天记录"

            );


            return;


        }







        setAiLoading(true);

        setMsg("");








        try{



            const res=

            await fetch(


                `${API}/api/ai/parse`,


                {


                    method:"POST",


                    headers:{


                        "Content-Type":

                        "application/json"


                    },



                    body:JSON.stringify({


                        text:chat


                    })



                }


            );








            const data=

            await res.json();







            if(!data.success){


                throw new Error(

                    "AI解析失败"

                );


            }








            setAiData(

                data.result

            );







            if(data.result["地点"]){


                setTutorAddress(

                    data.result["地点"]

                );


            }






        }

        catch(e:any){



            setMsg(

                e.message

            );



        }

        finally{


            setAiLoading(false);


        }



    }



    // =========================
    // 地址解析
    // =========================


    async function geocodeAddress(

        address:string,

        type:"mine"|"tutor"

    ){



        if(!address.trim()){


            setMsg(

                "请输入地址"

            );


            return;


        }







        if(type==="mine"){


            setMyLoading(true);


        }else{


            setTutorLoading(true);


        }







        setMsg("");








        try{



            const res=

            await fetch(


                `${API}/api/geocode`,


                {


                    method:"POST",


                    headers:{


                        "Content-Type":

                        "application/json"


                    },



                    body:JSON.stringify({


                        address


                    })



                }


            );








            const data=

            await res.json();








            if(!data.success){


                throw new Error(

                    data.detail ||

                    "地址解析失败"

                );


            }









            const point={


                lng:data.lng,


                lat:data.lat,


                name:data.formatted_address


            };








            if(type==="mine"){


                setMyLocation(point);


            }else{


                setTutorLocation(point);


            }






        }

        catch(e:any){



            setMsg(

                e.message

            );


        }

        finally{



            if(type==="mine"){


                setMyLoading(false);


            }else{


                setTutorLoading(false);


            }


        }



    }















    // =========================
    // 路线计算
    // =========================



    async function calculateRoute(){



        if(

            !myLocation ||

            !tutorLocation

        ){



            setMsg(

                "请先解析两个地址"

            );


            return;


        }








        setRouteLoading(true);


        setMsg("");









        try{



            const res=

            await fetch(


                `${API}/api/routes`,


                {


                    method:"POST",


                    headers:{


                        "Content-Type":

                        "application/json"


                    },



                    body:JSON.stringify({



                        origin_lng:

                        myLocation.lng,



                        origin_lat:

                        myLocation.lat,



                        destination_lng:

                        tutorLocation.lng,



                        destination_lat:

                        tutorLocation.lat



                    })



                }


            );








            const data=

            await res.json();








            if(!data.success){



                throw new Error(

                    "路线计算失败"

                );


            }








            setRoutes(data);






        }

        catch(e:any){



            setMsg(

                e.message

            );



        }

        finally{


            setRouteLoading(false);


        }



    }













    // =========================
    // 路线中文名称
    // =========================



    function routeName(

        key:string

    ){



        const names:any={



            driving:

            "🚗 驾车",




            bicycling:

            "🛵 电动车",




            transit:

            "🚇 公交地铁",




            walking:

            "🚶 步行"



        };




        return names[key] || key;



    } 
    


    return (


    <main className="

        min-h-screen

        bg-slate-100

        p-6

    ">



    <div className="

        max-w-5xl

        mx-auto

    ">





    <h1 className="

        text-4xl

        font-bold

        mb-8

    ">


        🏫 家教出行助手


    </h1>









    {
        msg &&


        <div className="

            bg-red-100

            text-red-700

            rounded-xl

            p-4

            mb-5

        ">


            {msg}


        </div>

    }









    {/* AI区域 */}



    <section className="

        bg-white

        rounded-2xl

        shadow

        p-6

        mb-6

    ">



        <h2 className="

            text-xl

            font-bold

        ">


            🤖 AI解析家教信息


        </h2>






        <textarea


            className="

            w-full

            h-36

            border

            rounded-xl

            p-4

            mt-4

            "




            value={chat}



            onChange={

                e=>

                setChat(

                    e.target.value

                )

            }




            placeholder="

粘贴家教聊天记录，例如：

英语家教，浦东新区XX小区，

周六下午2点，两小时

"


        />







        <button


            onClick={parseAI}



            className="

            bg-blue-600

            text-white

            px-6

            py-3

            rounded-xl

            mt-4

            "


        >



            {


            aiLoading

            ?

            "⏳ AI解析中..."

            :

            "🤖 开始解析"


            }



        </button>







        {

        aiData &&


        <div className="

            bg-blue-50

            rounded-xl

            mt-5

            p-5

        ">



        {

            Object.entries(aiData)

            .map(([k,v]:any)=>(


                <p

                key={k}

                className="mb-2"

                >


                <b>

                {

                labels[k] || k

                }


                </b>


                ：


                {String(v)}



                </p>



            ))


        }




        </div>


        }



    </section>









    {/* 地址区域 */}



    <section className="

        bg-white

        rounded-2xl

        shadow

        p-6

        mb-6

    ">




    <h2 className="text-xl font-bold">


        📍 地址设置


    </h2>








    <div className="mt-5">



        <p>

        我的当前位置

        </p>





        <input


            className="

            border

            rounded-xl

            w-full

            p-3

            mt-2

            "



            value={myAddress}



            onChange={

                e=>

                setMyAddress(

                    e.target.value

                )

            }




            placeholder="输入你的地址"



        />






        <button


            onClick={()=>


                geocodeAddress(

                    myAddress,

                    "mine"

                )


            }



            className="

            bg-green-600

            text-white

            rounded-xl

            px-5

            py-3

            mt-3

            "


        >



        {


        myLoading

        ?

        "⏳ 正在解析..."

        :

        "📍解析我的位置"



        }



        </button>








        {

        myLocation &&


        <p className="

        text-green-600

        mt-3

        ">


        ✅ 已定位：

        {myLocation.name}



        </p>


        }





    </div>









    <div className="mt-8">



        <p>

        家教地点

        </p>





        <input


            className="

            border

            rounded-xl

            w-full

            p-3

            mt-2

            "



            value={tutorAddress}



            onChange={

                e=>

                setTutorAddress(

                    e.target.value

                )

            }



            placeholder="输入家教地址"



        />







        <button


            onClick={()=>


                geocodeAddress(

                    tutorAddress,

                    "tutor"

                )


            }




            className="

            bg-green-600

            text-white

            rounded-xl

            px-5

            py-3

            mt-3

            "


        >



        {


        tutorLoading

        ?

        "⏳ 正在解析..."

        :

        "📍解析家教地点"



        }





        </button>







        {


        tutorLocation &&


        <p className="

        text-green-600

        mt-3

        ">


        ✅ 已定位：

        {tutorLocation.name}



        </p>


        }




    </div>





    </section>













    {/* 出行 */}



    <section className="

        bg-white

        rounded-2xl

        shadow

        p-6

    ">



        <h2 className="

        text-xl

        font-bold

        ">


        🚦 出行方案


        </h2>







        <button


            onClick={calculateRoute}



            className="

            bg-purple-600

            text-white

            rounded-xl

            px-6

            py-3

            mt-4

            "



        >



        {


        routeLoading

        ?

        "⏳计算中..."

        :

        "🚀计算最佳路线"



        }




        </button>









        {

        routes &&


        <div className="mt-6">





        <h3 className="

            text-xl

            font-bold

            mb-5

        ">



            ⭐最快：

            {

            routeName(

                routes.fastest

            )

            }



        </h3>








        {


        Object.entries(

            routes.routes

        )

        .map(([key,value]:any)=>(



            value.available &&



            <div

            key={key}

            className="

            border

            rounded-xl

            p-5

            mb-4

            "



            >



            <h4 className="

            font-bold

            text-lg

            ">


            {routeName(key)}


            </h4>







            <p>


            距离：

            {value.distance_km}

            km


            </p>






            <p>


            时间：

            {value.duration_minutes}

            分钟


            </p>




            </div>



        ))



        }





        </div>


        }







    </section>





    </div>


    </main>



    );


}