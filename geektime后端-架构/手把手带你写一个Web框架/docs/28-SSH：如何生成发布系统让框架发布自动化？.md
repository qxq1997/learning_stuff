你好，我是轩脉刃。

在前面的课程中，我们基本上已经完成了一个能同时生成前端和后端的框架hade，也能很方便对框架进行管理控制。下面两节课，我们来考虑框架的一些周边功能，比如部署自动化。

部署自动化其实不是一个框架的刚需，有很多方式可以将一个服务进行自动化部署，比如现在比较流行的Docker化或者CI/CD流程。

但是一些比较个人比较小的项目，比如一个博客、一个官网网站，**这些部署流程往往都太庞大了，更需要一个服务，能快速将在开发机器上写好、调试好的程序上传到目标服务器，并且更新应用程序**。这就是我们今天要实现的框架发布自动化。

所有的部署自动化工具，基本都依赖本地与远端服务器的连接，这个连接可以是FTP，可以是HTTP，但是更经常的连接是SSH连接。因为一旦我们购买了一个Web服务器，服务器提供商就会提供一个有SSH登录账号的服务器，我们可以通过这个账号登录到服务器上，来进行各种软件的安装，比如FTP、HTTP服务等。

基本上，SSH账号是我们拿到Web服务器的首要凭证，所以要设计的自动化发布系统也是依赖SSH的。

## SSH服务

那么在Golang中如何SSH连接远端的服务器呢？有一个[ssh](https://golang.org/x/crypto/ssh)库能完成SSH的远端连接。

这里介绍一个小知识，你可以看下这个ssh库的git：golang.org/x/crypto/ssh。它是在官网golang.org 下的，但是又不是官方的标准库，因为子目录是x。

这种库其实也是经过官方认证的，属于实验性的库，我们可以这么理解：**以golang.org/x/ 开头的库，都是官方认为这些库后续有可能成为标准库的一部份**，但是由于种种原因，现在还没有计划放进标准库中，需要更多时间打磨。但是这种库的维护者和开发者一般已经是Golang官方组的人员了。比如现在今年讨论热度很大的Golang泛型，据说也会先以实验库的形式出现。

不管怎么样，这种以golang.org/x/开头的库，成熟度已经非常高了，我们是可以放心使用的。来了解一下这个ssh库：

```go
package main

import (
	"bytes"
	"fmt"
	"log"

	"golang.org/x/crypto/ssh"
)

func main() {
	var hostKey ssh.PublicKey

	// ssh相关配置
	config := &ssh.ClientConfig{
		User: "username",
		Auth: []ssh.AuthMethod{
			ssh.Password("yourpassword"),
		},
		HostKeyCallback: ssh.FixedHostKey(hostKey),
	}
    // 创建client
	client, err := ssh.Dial("tcp", "yourserver.com:22", config)
	if err != nil {
		log.Fatal("Failed to dial: ", err)
	}
	defer client.Close()

    // 使用client做各种操作
	
	session, err := client.NewSession()
	if err != nil {
		log.Fatal("Failed to create session: ", err)
	}
	defer session.Close()

	var b bytes.Buffer
	session.Stdout = &b
	if err := session.Run("/usr/bin/whoami"); err != nil {
		log.Fatal("Failed to run: " + err.Error())
	}
	fmt.Println(b.String())
}
```

在这个官方示例中，我们可以看到ssh库作为客户端连接，最重要的是创建ssh.Client这个数据结构，而这个数据结构使用ssh.Dail能进行创建，创建的时候依赖ssh.ClientConfig这么一个配置结构。

是不是非常熟悉？和前面的Gorm、Redis一样，将SSH的连接部分封装成为hade框架的SSH服务，这样我们就能很方便地初始化一个ssh.Client了。

经过前面几节课，相信你已经非常熟悉这种套路了，我们就简要说明下ssh service的封装和实现思路。这节课的重点在后面对自动化发布系统的实现上。

ssh service的封装一样有三个部分，服务协议、服务提供者、服务实现。

服务协议我们提供GetClient方法：

```go
// SSHService 表示一个ssh服务
type SSHService interface {
   // GetClient 获取ssh连接实例
   GetClient(option ...SSHOption) (*ssh.Client, error)
}
```

而其中的SSHOption作为更新SSHConfig的函数：

```go
// SSHOption 代表初始化的时候的选项
type SSHOption func(container framework.Container, config *SSHConfig) error
```

我们封装配置结构为 SSHConfig：

```go
// SSHConfig 为hade定义的SSH配置结构
type SSHConfig struct {
   NetWork string
   Host    string
   Port    string
   *ssh.ClientConfig
}
```

对应的配置文件如下 config/testing/ssh.yaml，你可以看看每个配置的说明：

```yaml
timeout: 1s
network: tcp
web-01:
    host: 118.190.3.55 # ip地址
    port: 22 # 端口
    username: yejianfeng # 用户名
    password: "123456" # 密码
web-02:
    network: tcp
    host: localhost # ip地址
    port: 3306 # 端口
    username: jianfengye # 用户名
    rsa_key: "/Users/user/.ssh/id_rsa"
    known_hosts: "/Users/user/.ssh/known_hosts"
```

这里注意下，SSH的连接方式有两种，一种是直接使用用户名密码来连接远程服务器，还有一种是使用rsa key文件来连接远端服务器，所以这里的配置需要同时支持两种配置。**对于使用rsa key文件的方式，需要设置rsk\_key的私钥地址和负责安全验证的known\_hosts**。

定义好了SSH的服务协议，服务提供者和服务实现并没有什么特别，就不展示具体代码了，在GitHub上的[provider/ssh/provider.go](https://github.com/gohade/coredemo/blob/geekbang/28/framework/provider/ssh/provider.go) 和[provider/ssh/service.go](https://github.com/gohade/coredemo/blob/geekbang/28/framework/provider/ssh/service.go)中。我们简单说一下思路。

对于服务提供者，我们实现基本的五个函数Register/Boot/IsDefer/Param/Name。另外这个ssh服务并不是框架启动时候必要加载的，所以设置IsDefer为true，而Param我们就照例把服务容器container作为参数，传递给Register设定的实例化方法。

而SSH服务的具体实现，同样类似Redis，先配置更新，再查询是否已经实例化，若已经实例化，返回实例化对象；若没有实例化，实例化client，并且存在map中。

完成了SSH的服务协议、服务提供者、服务实例，我们就重点讨论下如何使用SSH的服务协议来实现自动化部署。

## 自动化部署

首先还是思考清楚自动化部署的命令设计。我们的hade框架是同时支持前后端的开发框架，所以自动化部署是需要同时支持前后端部署的，也就是说它的命令也需要支持前后端的部署，这里我们设计一个显示帮助信息的一级命令`./hade deploy` 和四个二级命令：

- `./hade deploy frontend` ，部署前端
- `./hade deploy backend` ，部署后端
- `./hade deploy all` ，同时部署前后端
- `./hade deploy rollback` ，部署回滚

同时也设计一下部署配置文件。

首先，我们是需要知道部署在哪个或者哪几个服务器上的，所以需要有一个数组配置项connections来定义部署服务器。而部署服务器的具体用户名密码配置，在前面SSH的配置里是存在的，所以这里直接把SSH的配置路径放在我们的connections中就可以了。

其次，还要知道我们要部署的远端服务器的目标文件夹是什么？所以这里需要有一个remote\_folder配置项来配置远端文件夹。

然后就是前端部署的配置frontend了。我们知道，在本地编译之后，会直接编译成了dist目录下的HTML/JS/CSS文件，这些文件直接上传到远端文件夹就是可以使用的了。

但是，在上传前端编译文件之前和在远端服务器执行一些命令之后，是有可能要做一些操作的。比如上传前先清空远端文件夹、上传后更新nginx等。所以这里，**我们设计两个数组结构pre\_action和post\_action来分别存放部署的前置命令和部署的后置命令**。

最后就是后端部署的配置backend。同前端部署一样，我们也有部署的前置命令和后置命令。但是后端编译还有一个不同点。

因为后端是Golang编译的，而它的编译其实是分平台的，加上Go支持“交叉编译”。就是说，比如我的工作机器是Mac操作系统，Web服务器是Linux操作系统，那么我需要编译Linux操作系统的后端程序，但是我可以直接在Mac操作系统上使用GOOS 和 GOARCH 来编译Linux操作系统的程序：

```go
GOOS=linux GOARCH=amd64 go build ./
```

这样编译出来的文件就是可以在Linux运行的后端进程了。所以在后端部署的配置项里面，我们增加GOOS 和 GOARCH分别表示后端的交叉编译参数。

完整的配置文件在config/development/deploy.yaml中：

```yaml
connections: # 要自动化部署的连接
    - ssh.web-01

remote_folder: "/home/yejianfeng/coredemo/"  # 远端的部署文件夹

frontend: # 前端部署配置
    pre_action: # 部署前置命令
        - "pwd"
    post_action: # 部署后置命令
        - "pwd"

backend: # 后端部署配置
    goos: linux # 部署目标操作系统
    goarch: amd64 # 部署目标cpu架构
    pre_action: # 部署前置命令
        - "pwd"
    post_action: # 部署后置命令
        - "chmod 777 /home/yejianfeng/coredemo/hade"
        - "/home/yejianfeng/coredemo/hade app restart"
```

好，配置文件设计好了，下面我们开始实现对应的命令。

其实估计你对如何实现，已经大致心中有数了。一级命令 `./hade deploy` 还是并没有什么内容，只是将帮助信息打印出来，之前也做过很多次，就不描述了。二级命令按之前的套路，一般是先编译，再部署，最后上传到目标服务器。

### 部署前端

看二级命令 `./hade deploy frontend`。对于部署前端，我们分为三个步骤：

- 创建要部署的文件夹；
- 编译前端文件到部署文件夹中；
- 上传部署文件夹，并且执行对应的前置和后置的shell。

在framework/command/deploy.go中：

```go
// deployFrontendCommand 部署前端
var deployFrontendCommand = &cobra.Command{
    Use:   "frontend",
    Short: "部署前端",
    RunE: func(c *cobra.Command, args []string) error {
        container := c.GetContainer()

        // 创建部署文件夹
        deployFolder, err := createDeployFolder(container)
        if err != nil {
            return err
        }

        // 编译前端到部署文件夹
        if err := deployBuildFrontend(c, deployFolder); err != nil {
            return err
        }

        // 上传部署文件夹并执行对应的shell
        return deployUploadAction(deployFolder, container, "frontend")
    },
}
```

这里可能你会有个疑惑，为什么要创建一个部署文件夹？我们直接将前端编译的dist目录上传到目标服务器不就行了么？来为你解答下。

部署服务是一个很小心的过程，因为它会影响现在的线上服务，而每次部署都是有可能失败的，也就很有可能需要进行回滚操作，就是我们前面定义的部署回滚操作命令 `./hade deploy rollback` 。**而回滚的时候，需要能找到某个特定版本的编译内容，这里就需要部署文件夹**。

这个部署文件夹我们定义为目录 deploy/xxxxxx，其中的xxxx直接设置为细化到秒的时间。对应的创建部署文件夹的函数如下：

```go
// 创建部署的folder
func createDeployFolder(c framework.Container) (string, error) {
   appService := c.MustMake(contract.AppKey).(contract.App)
   deployFolder := appService.DeployFolder()

   // 部署文件夹的名称
   deployVersion := time.Now().Format("20060102150405")
   versionFolder := filepath.Join(deployFolder, deployVersion)
   if !util.Exists(versionFolder) {
      return versionFolder, os.Mkdir(versionFolder, os.ModePerm)
   }
   return versionFolder, nil
}
```

这里的appService.DeployFolder() 是我们在appService下创建的一个新的目录deploy，在framework/contract/app.go中：

```go
// App 定义接口
type App interface {
   ...
   // DeployFolder 存放部署的时候创建的文件夹
   DeployFolder() string
   ...
}
```

有了这个部署文件夹，每次的发布都有“档案”存储了，这就为回滚命令提供了可能性。我们每次编译的文件，也都会先经过这个部署文件夹，再中转上传到目标服务器。

第一步创建部署文件夹实现了，我们再回头看下部署前端的第二个步骤，编译前端文件到部署文件夹。可以直接使用 buildFrontendCommand的RunE方法，它会将前端编译到dist目录下，然后我们再将dist目录文件拷贝到部署文件夹中：

```go
func deployBuildFrontend(c *cobra.Command, deployFolder string) error {
   container := c.GetContainer()
   appService := container.MustMake(contract.AppKey).(contract.App)

   // 编译前端
   if err := buildFrontendCommand.RunE(c, []string{}); err != nil {
      return err
   }

   // 复制前端文件到deploy文件夹
   frontendFolder := filepath.Join(deployFolder, "dist")
   if err := os.Mkdir(frontendFolder, os.ModePerm); err != nil {
      return err
   }

   buildFolder := filepath.Join(appService.BaseFolder(), "dist")
   if err := util.CopyFolder(buildFolder, frontendFolder); err != nil {
      return err
   }
   return nil
}
```

第三步，上传部署文件夹，并且执行对应的前置和后置的shell。

这个步骤的实现是今天这节课的重点了。首先遍历配置文件中的deploy.connections，明确我们要在哪几个远端节点中进行部署；然后对每个远端服务创建一个ssh.Client，由于前面已经写好了SSH服务，所以直接使用GetClient方法就能为每个节点创建一个sshClient了：

```go
for _, node := range deployNodes {
   sshClient, err := sshService.GetClient(ssh.WithConfigPath(node))
   if err != nil {
      return err
   }
   ...
}
```

接下来就要执行命令了，那怎么执行前置或者后置命令呢？

我们需要为每个命令创建一个session，然后使用session.CombinedOut来输出这个命令的结果，把每个命令的结果都输出在控制台中。相关代码如下：

```go
for _, action := range preActions {
   // 创建session
   session, err := sshClient.NewSession()
   if err != nil {
      return err
   }
   // 执行命令，并且等待返回
   bts, err := session.CombinedOutput(action)
   if err != nil {
      session.Close()
      return err
   }
   session.Close()
   
   // 执行前置命令成功
   logger.Info(context.Background(), "execute pre action", map[string]interface{}{
      "cmd":        action,
      "connection": node,
      "out":        strings.ReplaceAll(string(bts), "\n", ""),
   })
}
```

执行了前置命令之后，下面就是要把部署文件夹中的文件上传到目标服务器了。如何通过SSH服务将文件上传到目标服务器呢？

这里需要使用到一个成熟的第三方库 [sftp](https://github.com/pkg/sftp) 了，目前已经有1.1k star，采用BSD-2的开源协议，允许修改商用，但是要保留申明。这个库就是封装SSH的，将SFTP文件传输协议封装了一下。SFTP是什么？它是基于SSH协议来进行文件传输的一个协议，功能与FTP相似，区别就是它的连接通道使用SSH。

SFTP的底层连接实际上就是SSH，只是把传输的文件内容进行了一下加密等工作，增加了传输的安全性。所以**SFTP本质就是“使用SSH连接来完成文件传输功能”**。这点可以从它的实例化看出，sftp.Client的唯一参数就是ssh.Client。

```go
client, err := sftp.NewClient(sshClient)
if err != nil {
   return err
}
```

SFTP这个库，在初始化sftp.Client之后，会将这个client封装地和官方的本地操作文件OS库一样，你在使用sftp.Client的时候完全没有障碍。

比如，OS库创建一个文件是os.Create，在SFTP中就是使用client.Create；OS库获取一个文件信息的函数是os.Stat，在SFTP中就是client.Stat。但是注意下，这里完全是SFTP刻意将这个库函数设计的和OS库一样的，它们之间并没有什么嵌套关系。

我们使用ssh.Client初始化一个sftp.Client之后，写一个uploadFolderToSFTP的函数来实现将本地文件夹同步到远端文件夹：

```go
// 上传部署文件夹
func uploadFolderToSFTP(container framework.Container, localFolder, remoteFolder string, client *sftp.Client) error {
    logger := container.MustMake(contract.LogKey).(contract.Log)
    // 遍历本地文件
    return filepath.Walk(localFolder, func(path string, info os.FileInfo, err error) error {
        // 获取除了folder前缀的后续文件名称
        relPath := strings.Replace(path, localFolder, "", 1)
        if relPath == "" {
            return nil
        }
        // 如果是遍历到了一个目录
        if info.IsDir() {
            logger.Info(context.Background(), "mkdir: "+filepath.Join(remoteFolder, relPath), nil)
            // 创建这个目录
            return client.MkdirAll(filepath.Join(remoteFolder, relPath))
        }

        // 打开本地的文件
        rf, err := os.Open(filepath.Join(localFolder, relPath))
        if err != nil {
            return errors.New("read file " + filepath.Join(localFolder, relPath) + " error:" + err.Error())
        }
        // 检查文件大小
        rfStat, err := rf.Stat()
        if err != nil {
            return err
        }
        // 打开/创建远端文件
        f, err := client.Create(filepath.Join(remoteFolder, relPath))
        if err != nil {
            return errors.New("create file " + filepath.Join(remoteFolder, relPath) + " error:" + err.Error())
        }

        // 大于2M的文件显示进度
        if rfStat.Size() > 2*1024*1024 {
            logger.Info(context.Background(), "upload local file: "+filepath.Join(localFolder, relPath)+
                " to remote file: "+filepath.Join(remoteFolder, relPath)+" start", nil)
            // 开启一个goroutine来不断计算进度
            go func(localFile, remoteFile string) {
                // 每10s计算一次
                ticker := time.NewTicker(2 * time.Second)
                for range ticker.C {
                    // 获取远端文件信息
                    remoteFileInfo, err := client.Stat(remoteFile)
                    if err != nil {
                        logger.Error(context.Background(), "stat error", map[string]interface{}{
                            "err":         err,
                            "remote_file": remoteFile,
                        })
                        continue
                    }
                    // 如果远端文件大小等于本地文件大小，说明已经结束了
                    size := remoteFileInfo.Size()
                    if size >= rfStat.Size() {
                        break
                    }
                    // 计算进度并且打印进度
                    percent := int(size * 100 / rfStat.Size())
                    logger.Info(context.Background(), "upload local file: "+filepath.Join(localFolder, relPath)+
                        " to remote file: "+filepath.Join(remoteFolder, relPath)+fmt.Sprintf(" %v%% %v/%v", percent, size, rfStat.Size()), nil)
                }
            }(filepath.Join(localFolder, relPath), filepath.Join(remoteFolder, relPath))
        }

        // 将本地文件并发读取到远端文件
        if _, err := f.ReadFromWithConcurrency(rf, 10); err != nil {
            return errors.New("Write file " + filepath.Join(remoteFolder, relPath) + " error:" + err.Error())
        }
        // 记录成功信息
        logger.Info(context.Background(), "upload local file: "+filepath.Join(localFolder, relPath)+
            " to remote file: "+filepath.Join(remoteFolder, relPath)+" finish", nil)
        return nil
    })
}
```

这段代码长一点。首先我们使用功能filePath.Walk来遍历本地文件夹中的所有文件，如果遍历到的是子文件夹，就创建子文件夹，否则的话，我们就将本地文件上传到远端。而上传远端的操作大致就是三步：打开本地文件、打开远端文件、将本地文件传输到远端文件。

在上述函数中大致是这几句代码：

```go
// 打开本地的文件
rf, err := os.Open(filepath.Join(localFolder, relPath))

// 打开/创建远端文件
f, err := client.Create(filepath.Join(remoteFolder, relPath))

// 将本地文件并发读取到远端文件
if _, err := f.ReadFromWithConcurrency(rf, 10); err != nil 
```

SFTP提供了并发读取到远端文件ReadFromWithConcurrency的方法，我们可以使用这个并发读的方法提高上传效率。

但是即使是并发读，对于比较大的文件，还是需要等候比较长的时间。而这个等待时长，对于在控制台敲下部署命令的使用者来说是非常不友好的。我们希望能**每隔一段时间显示一下当前的部署进度**，这个怎么做呢？

这里我们设计大于2M的文件，执行这个操作。2M是我自己实验出来体验比较差的一个阈值。然后每2s就打印一下当前进度，所以使用了一个ticker，来计算时间。每次这个ticker结束的时候，计算一下远端文件的大小，再计算一下本地文件的大小。两者相除就是这个文件的上传进度，再使用日志打印就能打印出具体的进度了。

最后的效果如下：  
![](https://static001.geekbang.org/resource/image/08/4e/088379171caf4131231de7d635b6e34e.png?wh=1920x157)

到这里部署前端的代码就开发完成了。

### 部署后端

理解了如何部署前端，部署后端的对应方法基本如出一辙。唯一不同的地方就是编译。

编译Golang的后端需要指定对应的编译平台和编译CPU架构，就是前面说的GOOS和GOARCH。所以我们就不能直接使用build命令来编译后端了。改成定位go程序，来执行go build，并且需要修改输出文件路径，输出到部署文件夹中。

当然这个部署文件夹还是按照我们之前的设计为 deploy/xxxxxx，其中的xxxx直接设置为细化到秒的时间，继续在framework/command/deploy.go中写入：

```go
// 编译后端
path, err := exec.LookPath("go")
if err != nil {
   log.Fatalln("hade go: 请在Path路径中先安装go")
}
   // 组装命令
deployBinFile := filepath.Join(deployFolder, binFile)
cmd := exec.Command(path, "build", "-o", deployBinFile, "./")
cmd.Env = os.Environ()
   // 设置GOOS和GOARCH
if configService.GetString("deploy.backend.goos") != "" {
   cmd.Env = append(cmd.Env, "GOOS="+configService.GetString("deploy.backend.goos"))
}
if configService.GetString("deploy.backend.goarch") != "" {
   cmd.Env = append(cmd.Env, "GOARCH="+configService.GetString("deploy.backend.goarch"))
}
   // 执行命令
ctx := context.Background()
out, err := cmd.CombinedOutput()
if err != nil {
   logger.Error(ctx, "go build err", map[string]interface{}{
      "err": err,
      "out": string(out),
   })
   return err
}
logger.Info(ctx, "编译成功", nil)
```

同时除了生成二进制文件，还要记得把.env文件（如果有的话）、config目标文件传递到本地的部署目录：

```go
// 复制.env
if util.Exists(filepath.Join(appService.BaseFolder(), ".env")) {
   if err := util.CopyFile(filepath.Join(appService.BaseFolder(), ".env"), filepath.Join(deployFolder, ".env")); err != nil {
      return err
   }
}

// 复制config文件
deployConfigFolder := filepath.Join(deployFolder, "config", env)
if !util.Exists(deployConfigFolder) {
   if err := os.MkdirAll(deployConfigFolder, os.ModePerm); err != nil {
      return err
   }
}
if err := util.CopyFolder(filepath.Join(appService.ConfigFolder(), env), deployConfigFolder); err != nil {
   return err
}
```

自动化部署后端的命令，除了以上的编译文件到部署目录之外，其他部分都和自动化部署前端的命令一致：

```go
// deployBackendCommand 部署后端
var deployBackendCommand = &cobra.Command{
   Use:   "backend",
   Short: "部署后端",
   RunE: func(c *cobra.Command, args []string) error {
      container := c.GetContainer()

      // 创建部署文件夹
      deployFolder, err := createDeployFolder(container)
      if err != nil {
         return err
      }

      // 编译后端到部署文件夹
      if err := deployBuildBackend(c, deployFolder); err != nil {
         return err
      }

      // 上传部署文件夹并执行对应的shell
      return deployUploadAction(deployFolder, container, "backend")
   },
}
```

### 部署全部

而对于同时部署前后端命令，其实就是在编译阶段，把前端和后端同时进行编译，并且最终上传部署文件夹。同样放在framework/command/deploy.go：

```go
var deployAllCommand = &cobra.Command{
   Use:   "all",
   Short: "全部部署",
   RunE: func(c *cobra.Command, args []string) error {
      container := c.GetContainer()

      deployFolder, err := createDeployFolder(container)
      if err != nil {
         return err
      }

      // 编译前端
      if err := deployBuildFrontend(c, deployFolder); err != nil {
         return err
      }

      // 编译后端
      if err := deployBuildBackend(c, deployFolder); err != nil {
         return err
      }

      // 上传前端+后端，并执行对应的shell
      return deployUploadAction(deployFolder, container, "all")
   },
}
```

### 部署回滚

最后就是部署回滚操作，主要明确一下需要传递的参数：

一个是回滚版本号。这个版本号就是我们的部署目录的名称，前面说过部署目录为deploy/xxxxxx，xxxx设置为细化到秒的时间。比如20211110233354，表示是我们2021年11月10日23点33分54秒创建的版本。

另外一个就是标记希望回滚前端，还是后端，还是全部回滚。这里主要涉及执行前端的回滚命令，还是执行后端的回滚命令。

这两个参数我们直接以参数形式，跟在deploy rollback命令之后，如下：

```go
 ./hade deploy rollback 20211110233354 backend
```

明确了参数，它的具体实现就很简单了，因为它没有任何的编译过程，我们只需要把回滚版本所在目录的编译结果，上传到目标服务器就可以了，同样，我们把这个命令放在framework/command/deploy.go中：

```go
// deployRollbackCommand 部署回滚
var deployRollbackCommand = &cobra.Command{
   Use:   "rollback",
   Short: "部署回滚",
   RunE: func(c *cobra.Command, args []string) error {
      container := c.GetContainer()

      if len(args) != 2 {
         return errors.New("参数错误,请按照参数进行回滚 ./hade deploy rollback [version] [frontend/backend/all]")
      }

      version := args[0]
      end := args[1]

      // 获取版本信息
      appService := container.MustMake(contract.AppKey).(contract.App)
      deployFolder := filepath.Join(appService.DeployFolder(), version)

      // 上传部署文件夹并执行对应的shell
      return deployUploadAction(deployFolder, container, end)
   },
}
```

到这里四个自动化部署命令就都开发完成。我们来验证一下。

## 验证

要验证部署命令，我们当然需要有一个目标部署服务器，这是我设置的web-01服务器配置，在config/development/ssh.yaml中：

```yaml
timeout: 3s
network: tcp
web-01:
    host: 111.222.333.444 # ip地址
    port: 22 # 端口
    username: yejianfeng # 用户名
    password: "123456" # 密码
```

而在config/development/deploy.yaml中我的配置如下：

```yaml
connections: # 要自动化部署的连接
    - ssh.web-01

remote_folder: "/home/yejianfeng/coredemo/"  # 远端的部署文件夹

frontend: # 前端部署配置
    pre_action: # 部署前置命令
        - "pwd"
    post_action: # 部署后置命令
        - "pwd"

backend: # 后端部署配置
    goos: linux # 部署目标操作系统
    goarch: amd64 # 部署目标cpu架构
    pre_action: # 部署前置命令
        - "rm /home/yejianfeng/coredemo/hade"
    post_action: # 部署后置命令
        - "chmod 777 /home/yejianfeng/coredemo/hade"
        - "/home/yejianfeng/coredemo/hade app restart"
```

重点看后端部署配置。在部署后端之前，我们先运行一个rm 命令来将旧的hade二进制进程删除，然后部署后端文件，其中包括这个二进制进程。最后执行了两个命令，一个是chmod命令，保证上传上去的二进制进程命令可以执行；第二个就是./hade app restart命令，能将远端的命令启动。

这里就演示下部署后端服务 `./hade deploy backend` ，输出结果如下：  
![](https://static001.geekbang.org/resource/image/14/ac/14915cb398646c747875c4860e01b6ac.png?wh=1920x440)  
![](https://static001.geekbang.org/resource/image/2e/bb/2e70470a5e55e864aeea7e920e1eaabb.png?wh=1920x283)

我们看到，它成功地编译后端服务，到目标文件夹deploy/20211110233533， 并且上传了编译的hade命令，在远端启动了进程。

接着验证下回滚命令。在之前已经发布过版本 20211110233354 了。所以这里直接运行命令 `./hade deploy rollback 20211110233354 backend` 将版本回滚到 20211110233354。  
![](https://static001.geekbang.org/resource/image/fc/78/fc3280cfd8813169970f8d91c11f6578.png?wh=1920x403)  
![](https://static001.geekbang.org/resource/image/89/90/89390e826834862981bb94344dcfb090.png?wh=1920x297)

验证成功！

本节课我们对framework下的provider、contract、command目录都有修改。目录截图如下，供你对比查看，所有代码都已经上传到[geekbang/28](https://github.com/gohade/coredemo/tree/geekbang/28)分支了。  
![](https://static001.geekbang.org/resource/image/d8/0b/d89d6aaf4f25fab54dec747ef0f4700b.jpg?wh=2187x1292)

## 小结

今天我们实现了将代码自动化部署到Web服务器的机制。为了实现这个自动化部署，先实现了一个SSH服务，然后定制了一套自动化部署命令，包括部署前端、部署后端、部署全部和部署回滚。

虽然说这个由框架负责的自动化部署机制在大项目中可能用不上，毕竟现在大项目都采用Docker化和k8s部署了。不过对于小型项目，这种部署机制还是有其便利性的。所以我们的hade框架还是决定提供这个机制。

在实现这个机制的过程中，要做到熟练掌握Golang对于SSH、SFTP等库的操作。基本上这两个库的操作你熟悉了，就能在一个程序中同时自动化操作多个服务器了。在实际工作中，如果遇到类似的需求，可以按照这节课所展示的技术来自动化你的需求。

### 思考题

其实今天的内容涉及自动化运维的范畴了，我们就布置一个课外研究吧。自动化运维范畴中有一个很出名的自动化运维配置框架ansible，你可以去浏览下[Ansible中文权威指南](https://ansible-tran.readthedocs.io/en/latest)网站，学习一下ansible有哪些功能，分享一下你的学习心得。

欢迎在留言区分享你的思考。感谢你的收听，如果你觉得今天的内容对你有所帮助，也欢迎分享给你身边的朋友，邀请他一起学习。我们下节课见。
<div><strong>精选留言（4）</strong></div><ul>
<li><span>Vincent</span> 👍（0） 💬（2）<p>之前用到的makefile较多，想问老师如何选择呢，是集成到hade中还是在makefile中呢</p>2021-11-21</li><br/><li><span>taoist</span> 👍（0） 💬（0）<p>如果在Windows下运行部署到Linux平台，uploadFolderToSFTP函数里远端路径的filepath.Join需要用filepath.ToSlash包一下转换成Unix路径格式。</p>2024-01-30</li><br/><li><span>陈亦凡</span> 👍（0） 💬（1）<p>Mac cc
https:&#47;&#47;github.com&#47;messense&#47;homebrew-macos-cross-toolchains</p>2022-09-05</li><br/><li><span>陈亦凡</span> 👍（0） 💬（0）<p>这里交叉编时，gspt库使用了c，需要交叉编译，网上看了一下，如果使用musl的话，运行环境也要安装，请教下除了docker、musl还有别的方案吗？</p>2022-09-05</li><br/>
</ul>