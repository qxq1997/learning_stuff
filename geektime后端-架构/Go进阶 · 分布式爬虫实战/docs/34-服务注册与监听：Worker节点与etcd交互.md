你好，我是郑建勋。

这节课，让我们将Worker节点变为一个支持GRPC与HTTP协议访问的服务，让它最终可以被Master服务和外部服务直接访问。在Worker节点上线之后，我们还要将Worker节点注册到服务注册中心。

## GRPC与Protocol buffers

一般要在微服务中进行远程通信，会选择 [GRPC](https://grpc.io/) 或RESTful风格的协议。我们之前就提到过，GRPC的好处包括：

- 使用了HTTP/2传输协议来传输序列化后的二进制信息，让传输速度更快；
- 可以为不同的语言生成对应的Client库，让外部访问非常便利；
- 使用 Protocol Buffers 定义API的行为，提供了强大的序列化与反序列化能力；
- 支持双向的流式传输（Bi-directional streaming）。

GRPC默认使用 Protocol buffers 协议来定义接口，它有如下特点：

- 它提供了与语言、框架无关的序列化与反序列化的能力；
- 它序列化生成的字节数组比JSON更小，同时序列化与反序列化的速度也比JSON更快；
- 有良好的向后和向前兼容性。

Protocol buffers 将接口语言定义在以 .proto为后缀的文件中，之后 proto 编译器结合特定语言的运行库生成特定的SDK。这个SDK文件有助于我们在Client端访问，也有助于我们生成GRPC Server。

现在让我们来实战一下Protocol buffers 协议。

**第一步，**书写一个简单的文件hello.proto：

```plain
syntax = "proto3";
option go_package = "proto/greeter";

service Greeter {
	rpc Hello(Request) returns (Response) {}
}

message Request {
	string name = 1;
}

message Response {
	string greeting = 2;
}
```

proto协议很容易理解：

- `syntax = "proto3";` 标识我们协议的版本，每个版本的语言可能会有所不同，目前最新的使用最多的版本是proto3，它的语法你可以查看[官方文档](https://developers.google.com/protocol-buffers/docs/proto3)；
- option go\_package 定义生成的 Go 的 package 名；
- service Greeter 定义了一个服务Greeter，它的远程方法为Hello，Hello参数为结构体Request，返回值为结构体Response。

要根据这个proto文件生成Go对应的协议文件，我们需要做一下前置的工作：下载 proto 的编译器protoc，安装 protoc 指定版本的方式可以查看[官方的安装文档](https://grpc.io/docs/protoc-installation/)。

同时，我们还需要安装 protoc 的Go语言的插件。

```plain
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
```

**第二步，**输入命令protoc进行编译，编译完成后生成了hello.pb.go与hello\_grpc.pb.go两个协议文件。

```plain
protoc -I $GOPATH/src  -I . --go_out=.  --go-grpc_out=.  hello.proto
```

在hello\_grpc.pb.go中，我们会看到生成的文件为我们自动生成了GreeterServer接口，接口中有Hello方法。

```plain
type GreeterServer interface {
	Hello(context.Context, *Request) (*Response, error)
}
```

**第三步，**在我们的main函数中生成结构体Greeter，实现GreeterServer接口，然后调用生成协议文件中的pb.RegisterGreeterServer，将Greeter注册到GRPC server中。代码如下所示。要注意的是，xxx/proto/greeter需要替换为你自己的项目中协议文件的位置。

至此，我们就生成了一个GRPC服务了，该服务提供了Hello方法。

```plain
package main

import (
	pb "xxx/proto/greeter"
	"log"
	"net"

	"google.golang.org/grpc"
)
type Greeter struct {
	pb.UnimplementedGreeterServer
}

func (g *Greeter) Hello(ctx context.Context, req *pb.Request) (rsp *pb.Response, err error) {
	rsp.Greeting = "Hello " + req.Name
	return rsp, nil
}

func main() {
	println("gRPC server tutorial in Go")

	listener, err := net.Listen("tcp", ":9000")
	if err != nil {
		panic(err)
	}

	s := grpc.NewServer()
	pb.RegisterGreeterServer(s, &Greeter{})
	if err := s.Serve(listener); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
```

## go-micro 与GRPC-gateway

刚才我们看到了原生的生成GRPC服务器的方法。不过在我们的项目中，我打算用另一个目前微服务领域比较流行的框架go-micro来实现我们的GRPC服务器。

相比原生的方式，go-micro拥有更丰富的生态和功能，更方便的工具和API。例如，在go-micro中，服务注册可以方便地切换到etcd、ZooKeeper、Gossip、NATS等注册中心，方便我们实现服务注册功能。Server端也同时支持GRPC、HTTP等多种协议。

要在go-micro中实现GRPC服务器，我们同样需要利用前面的 proto文件生成的协议文件。不过，go-micro在此基础上进行了扩展，我们需要下载protoc-gen-micro插件来生成micro适用的协议文件。这个插件的版本需要和我们使用的go-micro版本相同。目前，最新的 go-micro版本为v4，我们这个项目就用最新的版本来开发。所以，我们需要先下载protoc-gen-micro v4版本：

```plain
go install github.com/asim/go-micro/cmd/protoc-gen-micro/v4@latest
```

接着输入如下命名，生成一个新的文件hello.pb.micro.go：

```plain
protoc -I $GOPATH/src  -I .  --micro_out=. --go_out=.  --go-grpc_out=.  hello.proto
```

在hello.pb.micro.go中，micro生成了一个接口GreeterHandler，所以我们需要在代码中实现这个新的接口：

```plain
type GreeterHandler interface {
	Hello(context.Context, *Request, *Response) error
}
```

用 go-micro 生成GRPC服务器的代码如下，Greeter结构体实现了GreeterHandler接口。代码调用pb.RegisterGreeterHandler将Greeter注册到micro生成的GRPC server中。另外如果要查看使用go-micro的样例，可以查看[example库](https://github.com/go-micro/examples)。

```plain
package main

import (
	pb "xxx/proto/greeter"
	"log"
	"context"
   "go-micro.dev/v4"
	"google.golang.org/grpc"
)

type Greeter struct{}

func (g *Greeter) Hello(ctx context.Context, req *pb.Request, rsp *pb.Response) error {
	rsp.Greeting = "Hello " + req.Name
	return nil
}

func main() {
	service := micro.NewService(
		micro.Name("helloworld"),
	)

	service.Init()

	pb.RegisterGreeterHandler(service.Server(), new(Greeter))

	if err := service.Run(); err != nil {
		log.Fatal(err)
	}
}
```

但到这里我们还不满足。GRPC在调试的时候比HTTP协议要繁琐，而且有些外部服务可能不支持使用GRPC协议，为了解决这些问题，我们可以让服务同时具备 GRPC 与 HTTP 的能力。

要实现这一目的，我们需要借助一个第三方库：[grpc-gateway](https://github.com/grpc-ecosystem/grpc-gateway)。grpc-gateway的功能就是生成一个HTTP的代理服务，然后这个HTTP代理服务会将HTTP请求转换为GRPC的协议，并转发到GRPC服务器中。从而实现了服务同时暴露HTTP接口与GRPC接口的目的。

要实现grpc-gateway的能力，我们需要对proto文件进行改造：

```plain
syntax = "proto3";
option go_package = "proto/greeter";
import "google/api/annotations.proto";

service Greeter {
	rpc Hello(Request) returns (Response) {
	    option (google.api.http) = {
            post: "/greeter/hello"
            body: "*"
        };
	}
}

message Request {
	string name = 1;
}

message Response {
	string greeting = 2;
}
```

这里我们引入了一个依赖google/api/annotations.proto，并且加入了自定义的option选项，grpc-gateway的插件会识别到这个自定义选项，并为我们生成HTTP代理服务。

要生成指定的协议文件，我们需要先安装grpc-gateway的插件：

```plain
go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway@latest
go install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2@latest
```

同时，提前下载依赖文件：google/api/annotations.proto。在这里，我手动下载了依赖文件并放入到了GOPATH中：

```plain
git clone git@github.com:googleapis/googleapis.git
mv googleapis/google  $(go env GOPATH)/src/google
```

最后，利用下面的指令将proto文件生成协议文件。要注意的是，这里我们同时加入了go-micro的插件和grpc-gateway的插件，两个插件之间可能存在命名冲突。所以我指定了grpc-gateway的选项 register\_func\_suffix 为 Gw，它能够让生成的函数名包含该Gw前缀，这就解决了命名冲突问题。

```plain
protoc -I $GOPATH/src  -I .  --micro_out=. --go_out=.  --go-grpc_out=.  --grpc-gateway_out=logtostderr=true,register_func_suffix=Gw:. hello.proto
```

这样我们就生成了4个文件，分别是hello.pb.go、hello.pb.gw.go、hello.pb.micro.go和hello\_grpc.pb.go。 其中，hello.pb.gw.go就是 grpc-gateway 插件生成的文件。

接下来我们借助 go-micro 与 grpc-gateway 为项目生成具备GRPC与HTTP能力的服务器，代码如下所示。

```plain
package main

import (
	"context"
	"fmt"
	pb "xxx/proto/greeter"
	gs "github.com/go-micro/plugins/v4/server/grpc"
	"github.com/grpc-ecosystem/grpc-gateway/v2/runtime"
	"go-micro.dev/v4"
	"go-micro.dev/v4/registry"
	"go-micro.dev/v4/server"
	"google.golang.org/grpc"
	"log"
	"net/http"
)

type Greeter struct{}

func (g *Greeter) Hello(ctx context.Context, req *pb.Request, rsp *pb.Response) error {
	rsp.Greeting = "Hello " + req.Name
	return nil
}

func main() {
	// http proxy
	go HandleHTTP()
  
  // grpc server 
	service := micro.NewService(
		micro.Server(gs.NewServer()),
		micro.Address(":9090"),
		micro.Name("go.micro.server.worker"),
	)

	service.Init()

	pb.RegisterGreeterHandler(service.Server(), new(Greeter))

	if err := service.Run(); err != nil {
		log.Fatal(err)
	}
}

func HandleHTTP() {
	ctx := context.Background()
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	mux := runtime.NewServeMux()
	opts := []grpc.DialOption{grpc.WithInsecure()}

	err := pb.RegisterGreeterGwFromEndpoint(ctx, mux, "localhost:9090", opts)
	if err != nil {
		fmt.Println(err)
	}

	http.ListenAndServe(":8080", mux)
}
```

其中，HandleHTTP 函数生成 HTTP 服务器，监听8080端口。同时，我们利用了 grpc-gateway 生成的 RegisterGreeterGwFromEndpoint 方法，指定了要转发到哪一个GRPC服务器。当访问该HTTP接口后，该代理服务器会将请求转发到GRPC服务器。

现在让我们来验证一下功能，我们使用HTTP协议去访问服务：

```plain
curl -H "content-type: application/json" -d '{"name": "john"}' http://localhost:8080/greeter/hello
```

返回结果如下：

```plain
{
    "greeting": "Hello "
}
```

这就表明我们已经成功地使用HTTP请求访问到了GRPC服务器。

## 注册中心与etcd

刚才，我们将Worker变成了GRPC服务器，也看到了go-micro的使用方式，接下来让我们看看如何用go-micro完成服务的注册。

在go-micro中使用micro.NewService生成一个service。其中，service可以用option的模式注入参数。而 micro.NewService 有许多默认的option，默认情况下生成的服务器并不是GRPC类型的。为了生成GRPC服务器，我们需要导入go-micro的 [GRPC插件库](https://github.com/go-micro/plugins/v4/server/grpc)，生成一个GRPC server注入到 micro.NewService 中。同时，micro.Address指定了服务器监听的地址，而micro.Name表示服务器的名字。

```plain
import (
  "go-micro.dev/v4"
  "github.com/go-micro/plugins/v4/server/grpc"
)

func main() {
	...
  // grpc server 
	service := micro.NewService(
		micro.Server(gs.NewServer()),
		micro.Address(":9090"),
		micro.Name("go.micro.server.worker"),
	)
}
```

在micro.NewService中还可以注入register模块，用于指定使用哪一个注册中心。我们的项目中将使用etcd作为注册中心。为了在go-micro v4中使用etcd作为注册中心，我们需要导入[etcd插件库](https://github.com/go-micro/plugins/v4/registry/etcd)，如下所示。这里的etcd注册模块仍然使用了option模式，registry.Addrs指定了当前etcd的地址。

```plain
import (
	etcdReg "github.com/go-micro/plugins/v4/registry/etcd"
)
func main() {
	...
	reg := etcdReg.NewRegistry(
			registry.Addrs(":2379"),
		)
	
	service := micro.NewService(
			micro.Server(gs.NewServer()),
			micro.Address(":9090"),
			micro.Registry(reg),
			micro.Name("go.micro.server"),
		)
}
```

接下来，让我们首先启动etcd服务器。启动服务器的方式有很多种，你可以参考[官方文档](https://github.com/etcd-io/etcd/releases/)。这里我利用Docker来启动一个etcd的服务器（关于Docker，我们在之后的章节会详细介绍）：

```plain
rm -rf /tmp/etcd-data.tmp && mkdir -p /tmp/etcd-data.tmp && \\
  docker rmi gcr.io/etcd-development/etcd:v3.5.6 || true && \\
  docker run \\
  -p 2379:2379 \\
  -p 2380:2380 \\
  --mount type=bind,source=/tmp/etcd-data.tmp,destination=/etcd-data \\
  --name etcd-gcr-v3.5.6 \\
  gcr.io/etcd-development/etcd:v3.5.6 \\
  /usr/local/bin/etcd \\
  --name s1 \\
  --data-dir /etcd-data \\
  --listen-client-urls <http://0.0.0.0:2379> \\
  --advertise-client-urls <http://0.0.0.0:2379> \\
  --listen-peer-urls <http://0.0.0.0:2380> \\
  --initial-advertise-peer-urls <http://0.0.0.0:2380> \\
  --initial-cluster s1=http://0.0.0.0:2380 \\
  --initial-cluster-token tkn \\
  --initial-cluster-state new \\
  --log-level info \\
  --logger zap \\
  --log-outputs stderr
```

要验证用Dokcer启动etcd服务器是否成功，功能是否正常，我们可以使用下面几条命令。这些命令会打印etcd的版本，并用一个简单的Key-Value值验证出put与get功能是正常的。

```plain
docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcd --version"
docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcdctl version"
docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcdctl endpoint health"
docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcdctl put foo bar"
docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcdctl get foo"
```

接下来，让我们启动go-micro构建的的GRPC服务器，服务的信息会注册到etcd中，并且会定时发送自己的健康状况用于保活。

下面让我们验证一下：

```plain
» docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcdctl get --prefix /"                                                            jackson@jacksondeMacBook-Pro
/micro/registry/go.micro.server/go.micro.server-707c1d61-2c20-42b4-95a0-6d3e8473727e
{"name":"go.micro.server","version":"latest","metadata":null,"endpoints":[{"name":"Say.Hello","request":{"name":"Request","type":"Request","values":[{"name":"name","type":"string","values":null}]},"response":{"name":"Response","type":"Response","values":[{"name":"msg","type":"string","values":null}]},"metadata":{}}],"nodes":[{"id":"go.micro.server-707c1d61-2c20-42b4-95a0-6d3e8473727e","address":"192.168.0.107:9090","metadata":{"broker":"http","protocol":"grpc","registry":"etcd","server":"grpc","transport":"grpc"}}]}
```

这里，命令 `get --prefix /` 表示获取前缀为/的Key。 我们会发现，go-micro注册到etcd中的Key为 `/micro/registry/c/go.micro.server-707c1d61-2c20-42b4-95a0-6d3e8473727e`，其中go.micro.server是服务的名字，最后的一串ID是随机字符。

我们可以通过在生成server时指定特殊的ID来替换掉随机的ID，如下所示：

```plain
func main(){
	...
	service := micro.NewService(
		micro.Server(gs.NewServer(
			server.Id("1"),
		)),
		micro.Address(":9090"),
		micro.Registry(reg),
		micro.Name("go.micro.server.worker"),
	)
}
```

这时会发现注册到etcd服务中的Key已经发生了变化：

```plain
» docker exec etcd-gcr-v3.5.6 /bin/sh -c "/usr/local/bin/etcdctl get --prefix /"                                                            jackson@jacksondeMacBook-Pro
/micro/registry/go.micro.server.worker/go.micro.server.worker-1
{"name":"go.micro.server.worker","version":"latest","metadata":null,"endpoints":[{"name":"Say.Hello","request":{"name":"Request","type":"Request","values":[{"name":"name","type":"string","values":null}]},"response":{"name":"Response","type":"Response","values":[{"name":"msg","type":"string","values":null}]},"metadata":{}}],"nodes":[{"id":"go.micro.server.worker-1","address":"192.168.0.107:9090","metadata":{"broker":"http","protocol":"grpc","registry":"etcd","server":"grpc","transport":"grpc"}}]}
```

上述完整的代码位于[v0.3.0](https://github.com/dreamerjackson/crawler)中。  
最后，我们也可以用一个GRPC的客户端去访问我们的服务器：

```plain
import (
	grpccli "github.com/go-micro/plugins/v4/client/grpc"
	"go-micro.dev/v4"
	"go-micro.dev/v4/registry"
	pb "xxx/proto/greeter"
}

func main() {
	reg := etcdReg.NewRegistry(
		registry.Addrs(":2379"),
	)
	// create a new service
	service := micro.NewService(
		micro.Registry(reg),
		micro.Client(grpccli.NewClient()),
	)

	// parse command line flags
	service.Init()

	// Use the generated client stub
	cl := pb.NewGreeterService("go.micro.server.worker", service.Client())

	// Make request
	rsp, err := cl.Hello(context.Background(), &pb.Request{
		Name: "John",
	})
	if err != nil {
		fmt.Println(err)
		return
	}

	fmt.Println(rsp.Greeting)
}
```

这里 pb.NewGreeterService 的第一个参数代表服务器的注册名。如果运行后能够正常地返回结果，代表GRPC客户端访问GRPC服务器成功了。GRPC返回的结果如下所示：

```plain
» go run main.go     
Hello John
```

## 总结

好了，总结一下。这节课，我们为Worker服务构建了GRPC服务器和HTTP服务器。其中，HTTP服务器是用grpc-gateway生成的一个代理，它最终也会访问GRPC服务器。构建GRPC服务器需要安装一些必要的依赖，还要书写定义接口行为的proto文件。

在这节课的例子中，我们使用了go-micro微服务框架实现了GRPC服务器，它为微服务提供了比较丰富的能力，然后我们使用go-micro的插件将服务注册到了etcd注册中心当中。客户端可以通过服务器注册的服务名找到该服务并完成调用。如果同一个服务名找到了多个服务器，go-micro会默认使用负载均衡机制保障公平性。

## 课后题

这节课，我们用HTTP POST请求访问了HTTP代理服务服务器：

```plain
curl -H "content-type: application/json" -d '{"name": "john"}' http://localhost:8080/greeter/hello
```

返回结果如下：

```plain
{
    "greeting": "Hello "
}
```

但是不知道你注意到没有，我们预期返回的信息应该是：

```plain
{
    "greeting": "Hello john"
}
```

你知道是哪个地方出现了问题吗？

欢迎你跟我交流讨论，我们也会在后面修复这一问题。下节课见！
<div><strong>精选留言（5）</strong></div><ul>
<li><span>shuff1e</span> 👍（0） 💬（1）<p>mux := runtime.NewServeMux()
看起来是HandleHTTP没指定路由？name是从body取，还是从query参数取，也没指定？</p>2022-12-27</li><br/><li><span>出云</span> 👍（1） 💬（2）<p>回答一下结尾问题：按文中的写法其实不会出现只返回“Hello”的情况。检查了下代码仓库v3.0.0版本。hello.proto文件中hello方法的option注解少了body字段。按这种写法生成proto文件再次运行，才复现了文末说的问题，所以问题就是出在少了一行`body:  &quot;*&quot;`。

（另外，给protoc安装grpc-gateway的两个插件后，生成的hello.pb.micro.go文件中的NewGreeterEndpoints()函数中返回的api.Endpoint对象会多一个不存在的Body字段，需要删掉才能正常编译。）</p>2023-03-17</li><br/><li><span>出云</span> 👍（0） 💬（0）<p>产生多余Body字段的原因也找到了。是因为按文中给的包路径安装不到最新的protoc-gen-micro插件。根据go-micro的官方repo，该插件目前的包路径是` github.com&#47;go-micro&#47;generator&#47;cmd&#47;protoc-gen-micro@latest `。 去$GOPATH&#47;bin 把旧的可执行文件删了，执行`go install 新路径`，再重新生成pb文件即可解决问题。 </p>2023-03-17</li><br/><li><span>tcyi</span> 👍（0） 💬（0）<p>google&#47;api&#47;annotations.proto 报错，按照老师提供的方法 不能成功，win10环境
</p>2023-02-20</li><br/><li><span>viclilei</span> 👍（0） 💬（1）<p>docker etcd error</p>2023-01-11</li><br/>
</ul>