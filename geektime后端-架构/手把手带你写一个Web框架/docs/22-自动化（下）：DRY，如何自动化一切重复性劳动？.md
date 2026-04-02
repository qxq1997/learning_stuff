你好，我是轩脉刃。

上一节课我们增加了自动化创建服务工具、命令行工具，以及中间件迁移工具。你会发现，这些工具实现起来并不复杂，但是在实际工作中却非常有用。今天我们继续思考还能做点什么。

我们的框架是定义了业务的目录结构的，每次创建一个新的应用，都需要将AppService中定义的目录结构创建好，如果这个行为能自动化，实现**一个命令就能创建一个定义好所有目录结构，甚至有demo示例的新应用**呢？是不是有点心动，这就是我们今天要实现的工具了，听起来功能有点庞大，所以我们还是慢慢来，先设计再实现。

## 初始化脚手架设计

这个功能倒不是什么新想法，有用过Vue的同学就知道，Vue官网有介绍一个 `vue create` [命令](https://cli.vuejs.org/zh/guide/creating-a-project.html)，可以从零开始创建一个包含基本Vue结构的目录，这个目录可以直接编译运行。

在初始化一个Vue项目的时候，大多数刚接触Vue的同学对框架的若干文件还不熟悉，很容易建立错误vue的目录结构，而这个工具能帮Vue新手们有效规避这种错误。

同理，我们的框架也有基本的hade结构的目录，初学者在创建hade应用的时候，也大概率容易建立错误目录。所以参考这一点，让自己的框架也有这么一个命令，能直接创建一个新的包含hade框架业务脚手架目录的命令。这样，能很大程度方便使用者就在这个脚手架目录上不断开发，完成所需的业务功能。

我们要设计的命令是一个一级命令`./hade new` 。一般来说，新建命令创建一个脚手架，要做的事情就是：

- 确定目标目录，如果没有就创建目录
- 创建业务模块目录
- 初始化go module 模块，补充模块名称、框架版本号
- 在业务模块目录中创建对应的文件代码

我们跟着这个思路走。先梳理一下在这个命令中，要传入的参数有哪些？

首先是目录，在控制台目录之下要创建一个子目录，这个**子目录的名称，是需要用户传递进入的**。不过，这个参数记得做一下验证，如果子目录已经存在了，给用户一个提示，是直接删除原先的子目录？还是停止操作？如果用户需要删除原先的子目录，我们就直接删除。

其次是**需要用户传入新应用的模块名称**，也就是go.mod中的module后面的名称，一般会设置为应用的项目地址，比如github.com/jianfengye/testdemo。关于模块名称，我们要详细做一下解说。

### 业务、框架模块地址

一直到这一节课的GitHub地址，不知道你有没有疑惑，别的框架，比如Gin、Echo，都是把框架代码放在GitHub上，比如github/gin-gonic/gin，而业务代码是单独存放的。但我们这个项目github.com/gohade/coredemo，却是把业务代码和框架代码都放在一个项目中？

其实是这样，这个项目github.com/gohade/coredemo，是我为geekbang这个课程单独设置的项目，将hade框架的每个实现步骤，重新在这个项目做了一次还原。而 github.com/gohade/hade 才是我们最终的项目地址。所以不管在 coredemo 这个项目还是 hade这个项目，go.mod 中的module 都是叫做 github.com/gohade/hade。

**但是即使是最终的github.com/gohade/hade项目，我们的业务代码app目录和框架目录 framework目录也是在一个项目里的**，按道理说在这个hade项目中，应该只有framework目录的内容即可啊？  
![](https://static001.geekbang.org/resource/image/15/54/15d2de9d05e7f68dc072708945beaa54.png?wh=400x562)

这里我是这么设计的，将framework目录和其他的业务目录都同时放在github.com/gohade/hade项目中，这样这个项目也同时就是我们hade框架的一个示例项目。只是这个项目带着framework目录而已。

后续如果要创建一个新的业务项目，比如github.com/jianfengye/testdemo。我们**不是做加法把业务文件夹一点点复制过来，而是做依赖这个github.com/gohade/hade项目做减法**，把不必要的文件夹（比如框架文件夹）删掉。

即我们只需要直接拷贝这个github.com/gohade/hade 项目，并且将其中的framework目录删除，保留业务目录，同时把go.mod中的原先的“github.com/gohade/hade”模块名修改为github.com/jianfengye/testdemo这个模块名，用到hade框架的部分直接引用“github.com/gohade/hade/framework” 即可。

这就是说，如果你要创建的项目的模块名为github.com/jianfengye/testdemo，go.mod应该如下：

```go
// 这里是你的模块地址
module github.com/jianfengye/testdemo

go 1.15

require (
   // 这里引用github.com/gohade/hade
   github.com/gohade/hade v0.0.2
   ...

)
```

目录应该和github.com/gohade/hade 只有一处不同：没有framework目录。  
![](https://static001.geekbang.org/resource/image/d4/63/d4208f4ea094ba3404da935a1bf21263.png?wh=254x414)

而在你自己的github.com/jianfengye/testdemo 项目中的所有文件，如果是框架中的，也就是要使用hade已有的服务提供者、中间件、命令行的时候，是使用`import github.com/gohade/hade/framework`；而在使用自己的服务提供者、中间件、命令行，所有在业务目录内的结构的时候，是使用 `import github.com/jianfengye/testdemo/xxx`。

比如main.go 就形如：

```go
package main

import (
    // 业务的目录app内的文件
   "github.com/jianfengye/testdemo/app/console"
   "github.com/jianfengye/testdemo/app/http"
   // 框架目录的文件
   "github.com/gohade/hade/framework"
   "github.com/gohade/hade/framework/provider/app"
   "github.com/gohade/hade/framework/provider/config"
   "github.com/gohade/hade/framework/provider/distributed"
   "github.com/gohade/hade/framework/provider/env"
   "github.com/gohade/hade/framework/provider/id"
   "github.com/gohade/hade/framework/provider/kernel"
   "github.com/gohade/hade/framework/provider/log"
   "github.com/gohade/hade/framework/provider/trace"
)

func main() {
   // 初始化服务容器
   container := framework.NewHadeContainer()
   // 绑定App服务提供者
   container.Bind(&app.HadeAppProvider{})
   // 后续初始化需要绑定的服务提供者...
   container.Bind(&env.HadeEnvProvider{})
   container.Bind(&distributed.LocalDistributedProvider{})
   container.Bind(&config.HadeConfigProvider{})
   container.Bind(&id.HadeIDProvider{})
   container.Bind(&trace.HadeTraceProvider{})
   container.Bind(&log.HadeLogServiceProvider{})

   // 将HTTP引擎初始化,并且作为服务提供者绑定到服务容器中
   if engine, err := http.NewHttpEngine(); err == nil {
      container.Bind(&kernel.HadeKernelProvider{HttpEngine: engine})
   }

   // 运行root命令
   console.RunCommand(container)
}
```

说到这里相信你应该理解了，最终我们这个框架只维护 github.com/gohade/hade 这么一个项目，**这个项目中的framework目录，存放的是框架所有的代码，而framework之外的目录和文件都是示例代码**。

所以，回到今天的主题，让 `./hade new` 命令创建一个脚手架，要做的事情现在就变成了：

- 下载github.com/gohade/hade项目到目标文件夹
- 删除framework目录
- 修改go.mod中的模块名称
- 修改go.mod中的require信息，增加require github.com/gohade/hade
- 修改所有文件使用业务目录的地方，将原本使用“github.com/gohade/hade/app” 的所有引用改成 “\[模块名称]/app”

也就是说第二个输入，我们需要用户确切输入一个模块名称。

### 框架的版本号信息

除了新建时必须的子目录的名称和新建模块的名称，第三个需要用户输入的是hade的版本号。

我们的hade框架是会不断变化的，和Golang语言一样，使用形如v1.2.3这样的版本号进行迭代，v代表版本的英文缩写，1代表的是大版本，只有非常大变更的时候我们才会更新这个版本；2代表的是小版本，有接口变更或者类库变更之类的时候我们会迭代这个版本；3代表的是补丁版本，如果发现有需要补丁修复的地方，就会使用这个版本。

而每个hade框架版本对应的脚手架，也有可能有一定变化的。因为在脚手架中，我们会把框架的使用示例等放在应用代码中。

hade框架的每个版本发布时，都会打对应的tag，每个tag我们都会在GitHub上发布一个release版本与之对应，比如截止到10/7日，已经发布了v0.0.1和v0.0.2两个tag和release版本，你可以直接通过[GitHub地址](https://github.com/gohade/hade/releases)来进行查看。  
![](https://static001.geekbang.org/resource/image/ba/a4/ba9e3152dbc9469327a820d1cac205a4.png?wh=1323x331)![](https://static001.geekbang.org/resource/image/a7/dc/a77a6affec75c2051df984fcff89fbdc.png?wh=1284x886)

所以回到 `./hade new` 命令，第三个需要用户输入的就是这个版本号，如果用户需要创建一个v0.0.1版本的hade脚手架，则需要输入v0.0.1，如果用户没有输入，我们默认使用最新的版本。

好了，简单总结一下，用户目前输入的三个信息：

- 目录名，最终是“当前执行目录+目录名”
- 模块名，最终创建应用的module
- 版本号，对应的hade的release版本号

用户输入相关的代码如下，在我们的 framework/command/new.go中：

```go
     var name string
      var folder string
      var mod string
      var version string
      var release *github.RepositoryRelease
      {
         prompt := &survey.Input{
            Message: "请输入目录名称：",
         }
         err := survey.AskOne(prompt, &name)
         if err != nil {
            return err
         }

         folder = filepath.Join(currentPath, name)
         if util.Exists(folder) {
            isForce := false
            prompt2 := &survey.Confirm{
               Message: "目录" + folder + "已经存在,是否删除重新创建？(确认后立刻执行删除操作！)",
               Default: false,
            }
            err := survey.AskOne(prompt2, &isForce)
            if err != nil {
               return err
            }

            if isForce {
               if err := os.RemoveAll(folder); err != nil {
                  return err
               }
            } else {
               fmt.Println("目录已存在，创建应用失败")
               return nil
            }
         }
      }
      {
         prompt := &survey.Input{
            Message: "请输入模块名称(go.mod中的module, 默认为文件夹名称)：",
         }
         err := survey.AskOne(prompt, &mod)
         if err != nil {
            return err
         }
         if mod == "" {
            mod = name
         }
      }
      {
         // 获取hade的版本
         client := github.NewClient(nil)
         prompt := &survey.Input{
            Message: "请输入版本名称(参考 https://github.com/gohade/hade/releases，默认为最新版本)：",
         }
         err := survey.AskOne(prompt, &version)
         if err != nil {
            return err
         }
         if version != "" {
            // 确认版本是否正确
            release, _, err = client.Repositories.GetReleaseByTag(context.Background(), "gohade", "hade", version)
            if err != nil || release == nil {
               fmt.Println("版本不存在，创建应用失败，请参考 https://github.com/gohade/hade/releases")
               return nil
            }
         }
         if version == "" {
            release, _, err = client.Repositories.GetLatestRelease(context.Background(), "gohade", "hade")
            version = release.GetTagName()
         }
      }
```

## 初始化脚手架具体实现

有了这三个信息，我们将之前讨论的 hade new 命令的步骤再详细展开讨论：

- 下载github.com/gohade/hade项目到目标文件夹
- 删除framework目录
- 修改go.mod中的模块名称
- 修改go.mod中的require信息，增加require github.com/gohade/hade
- 修改所有文件使用业务目录的地方，将原本使用“github.com/gohade/hade/app” 的所有引用改成 “\[模块名称]/app”

第一步下载稍微复杂一点，我们重点说，剩下四步就是简单的按部就班了。

### 项目下载

因为有版本号更新的可能，其中的第一步“复制github.com/gohade/hade项目到目标文件夹” ，我们就要变化为“下载github.com/gohade/hade 的某个release版本到目标文件夹”。

这个能怎么做呢？可以想到GitHub有提供对外的开放平台接口 api.github.com，你可以看它的[官方文档地址](https://docs.github.com/cn/rest/reference/repos)。

我们可以通过开放平台接口，对公共的GitHub仓库进行信息查询。比如要查看某个GitHub仓库的release分支，可以通过调用“[/repos/{owner}/{repo}/releases](https://docs.github.com/cn/rest/reference/repos#list-releases)”，而获取某个GitHub仓库的最新release分支，可以通过调用“[/repos/{owner}/{repo}/releases/latest](https://docs.github.com/cn/rest/reference/repos#get-the-latest-release)”。

使用GitHub的开放平台接口，是可以直接调用，但是这个方法有个明显的问题，我们还要手动封装这个接口调用。

其实更简单的方式是，使用Google给我们提供好的Golang语言的SDK，[go-github](https://github.com/google/go-github)。这个库本质就是封装了GitHub的调用接口。比如获取仓库github.com/gohade/hade的release分支：

```go
client := github.NewClient(nil)
releases, _, err = client.Repositories.GetReleases(context.Background(), "gohade", "hade")
```

而获取它最新release分支也很简单：

```go
client := github.NewClient(nil)
release, _, err = client.Repositories.GetLatestRelease(context.Background(), "gohade", "hade")
```

在返回的RepositoryRelease结构中，我们可以找到下载这个release版本的各种信息。其中包括release版本对应的版本号信息和zip下载地址：

```go
// RepositoryRelease represents a GitHub release in a repository.
type RepositoryRelease struct {
   // 对应的版本号信息
   TagName                *string `json:"tag_name,omitempty"`
   ...
   // release版本的zip下载地址
   ZipballURL  *string         `json:"zipball_url,omitempty"`
   
   ...
}
```

库信息了解到这里，我们回到刚才要执行的第一步“下载github.com/gohade/hade 的某个release版本到目标文件夹”，就可以使用这个zip下载地址，下载对应的zip包，并且使用unzip解压这个zip目录。

对于下载zip包，直接使用http.Get就能下载了。这个函数我们封装在framework/util/file.go中：

```go
// DownloadFile 下载url中的内容保存到本地的filepath中
func DownloadFile(filepath string, url string) error {

   // 获取
   resp, err := http.Get(url)
   if err != nil {
      return err
   }
   defer resp.Body.Close()

   // 创建目标文件
   out, err := os.Create(filepath)
   if err != nil {
      return err
   }
   defer out.Close()

   // 拷贝内容
   _, err = io.Copy(out, resp.Body)
   return err
}
```

而unzip解压，我们可以使用Golang标准库的 archive/zip，来读取zip包中的内容，然后将每个文件都复制到目标目录中。unzip的基本逻辑就是使用zip包读取压缩文件，然后遍历压缩文件中的文件夹，将对应的文件和文件夹都复制到目标目录中。

具体代码存放在framework/util/zip.go中，代码中也做了对应注释：

```go
// Unzip 解压缩zip文件，复制文件和目录都到目标目录中
func Unzip(src string, dest string) ([]string, error) {

   var filenames []string

   // 使用archive/zip读取
   r, err := zip.OpenReader(src)
   if err != nil {
      return filenames, err
   }
   defer r.Close()

   // 所有内部文件都读取
   for _, f := range r.File {

      // 目标路径
      fpath := filepath.Join(dest, f.Name)

      if !strings.HasPrefix(fpath, filepath.Clean(dest)+string(os.PathSeparator)) {
         return filenames, fmt.Errorf("%s: illegal file path", fpath)
      }

      filenames = append(filenames, fpath)

      if f.FileInfo().IsDir() {
         // 如果是目录，则创建目录
         os.MkdirAll(fpath, os.ModePerm)
         continue
      }

      //否则创建文件
      if err = os.MkdirAll(filepath.Dir(fpath), os.ModePerm); err != nil {
         return filenames, err
      }

      outFile, err := os.OpenFile(fpath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode())
      if err != nil {
         return filenames, err
      }

      rc, err := f.Open()
      if err != nil {
         return filenames, err
      }
      
      // 复制内容
      _, err = io.Copy(outFile, rc)

      
      outFile.Close()
      rc.Close()

      if err != nil {
         return filenames, err
      }
   }
   return filenames, nil
}
```

但是你在调试的过程中就会发现，下载的zip包中带有一层目录，gohade-hade-xxxx，目录下面才是我们需要的hade库的真实代码。如果直接复制zip包，就会在目标文件夹下创建gohade-hade-xxx目录，但是这个目录层级并不是我们想要的。

所以这里要修改“下载github.com/gohade/hade 的某个release版本到目标文件夹”的实现步骤，大致思路就是**通过创建和删除一个临时目录，来达到把zip包解压的目的**。

具体操作就是，先创建临时目录 template-hade-version-\[timestamp]，然后下载release的zip包地址临时目录，并命名为template.zip，在临时目录中解压zip包 template.zip，生成gohade-hade-xxxx目录。这个时候就完成了一半，拿到了需要的hade库真实代码。

之后，查找临时目录中名为 gohade-hade-开头的目录，定位到gohade-hade-xxx目录，将这个目录使用os.rename 移动成为目标文件夹。最后收尾删除临时目录。

对应代码在framework/command/new.go中：

```go
    templateFolder := filepath.Join(currentPath, "template-hade-"+version+"-"+cast.ToString(time.Now().Unix()))
      os.Mkdir(templateFolder, os.ModePerm)
      fmt.Println("创建临时目录", templateFolder)

      // 拷贝template项目
      url := release.GetZipballURL()
      err := util.DownloadFile(filepath.Join(templateFolder, "template.zip"), url)
      if err != nil {
         return err
      }
      fmt.Println("下载zip包到template.zip")

      _, err = util.Unzip(filepath.Join(templateFolder, "template.zip"), templateFolder)
      if err != nil {
         return err
      }

      // 获取folder下的gohade-hade-xxx相关解压目录
      fInfos, err := ioutil.ReadDir(templateFolder)
      if err != nil {
         return err
      }
      for _, fInfo := range fInfos {
         // 找到解压后的文件夹
         if fInfo.IsDir() && strings.Contains(fInfo.Name(), "gohade-hade-") {
            if err := os.Rename(filepath.Join(templateFolder, fInfo.Name()), folder); err != nil {
               return err
            }
         }
      }
      fmt.Println("解压zip包")

      if err := os.RemoveAll(templateFolder); err != nil {
         return err
      }
      fmt.Println("删除临时文件夹", templateFolder)
```

第一步的源码复制完成之后，就是后面很简单的四步了，我直接把顺序写在注释中了，你可以对照代码看，同样在framework/command/new.go中：

```go
os.RemoveAll(path.Join(folder, ".git"))
      fmt.Println("删除.git目录")

      // 删除framework 目录
      os.RemoveAll(path.Join(folder, "framework"))
      fmt.Println("删除framework目录")

      filepath.Walk(folder, func(path string, info os.FileInfo, err error) error {
         if info.IsDir() {
            return nil
         }

         c, err := ioutil.ReadFile(path)
         if err != nil {
            return err
         }
         // 修改go.mod中的模块名称、修改go.mod中的require信息
         // 增加require github.com/gohade/hade
         if path == filepath.Join(folder, "go.mod") {
            fmt.Println("更新文件:" + path)
            c = bytes.ReplaceAll(c, []byte("module github.com/gohade/hade"), []byte("module "+mod))
            c = bytes.ReplaceAll(c, []byte("require ("), []byte("require (\n\tgithub.com/gohade/hade "+version))
            err = ioutil.WriteFile(path, c, 0644)
            if err != nil {
               return err
            }
            return nil
         }
         // 最后修改所有文件使用业务目录的地方，
         // 将原本使用“github.com/gohade/hade/app” 的所有引用
         // 改成 “[模块名称]/app”
         isContain := bytes.Contains(c, []byte("github.com/gohade/hade/app"))
         if isContain {
            fmt.Println("更新文件:" + path)
            c = bytes.ReplaceAll(c, []byte("github.com/gohade/hade/app"), []byte(mod+"/app"))
            err = ioutil.WriteFile(path, c, 0644)
            if err != nil {
               return err
            }
         }

         return nil
      })
      fmt.Println("创建应用结束")
      fmt.Println("目录：", folder)
      fmt.Println("====================================================")
      return nil
```

### 验证

最后我们验证下。使用 `./hade new` 创建一个目录名称为testdemo、模块名为 github.com/jianfengye/testdemo、版本为最新版本v0.0.2的脚手架。  
![](https://static001.geekbang.org/resource/image/82/c5/8211f96faf4ff3a4b86e2213b0678ec5.png?wh=691x574)

进入testdemo目录，执行 `go build` 命令可直接编译，并且生成了可运行的二进制文件。  
![](https://static001.geekbang.org/resource/image/44/ff/446ac21ea8f351989778fa83437be2ff.png?wh=1025x646)

自动化初始化脚手架命令完成！

今天所有代码都保存在GitHub上的[geekbang/22](https://github.com/gohade/coredemo/tree/geekbang/22)分支了。附上目录结构供你对比查看，只修改了framework/command/目录下的new.go代码。  
![](https://static001.geekbang.org/resource/image/f4/95/f4e3c5e4f359b3a005854e9451b32395.png?wh=392x996)

## 小结

今天我们增加了一个新的命令，自动化初始化脚手架的命令设计，让hade框架也可以像Vue框架一样，直接使用一个二进制命令 `./hade new` 创建一个脚手架。我们把框架和脚手架示例代码同时放在github.com/gohade/hade仓库中，实现了框架和脚手架示例代码版本的关联。

在创建脚手架的时候，我们是**基于这个仓库的某个tag版本做减法**，而不是费劲地做加法来进行创建。

同时在每次更新框架的时候，我们也会自然而然更新这个示例代码，**框架和示例代码永远是一一对应的，而下载的时候会保留这种一一对应的关系**。这种设计让hade版本的框架设计更为方便了。

这两节课的四个工具的自动化，是我们目前能想到的比较常用的“重复性”劳动了。当然随着框架使用的深入，还可能有更多的自动化需求，但是基本上都和这几个自动化命令是同样的套路，所以掌握这两节课的内容和方法，你已经可以自行简化这些“重复性”劳动了。

## 思考题

这节课的代码比较多，希望你能仔细对比GitHub上的代码。经过这两节课的练习，你可以思考一下，作为一个“懒惰”的程序员，在hade框架中，我们还有哪些工作还可以自动化么？

欢迎在留言区分享你的思考。如果你觉得有收获，也欢迎把今天的内容分享给身边的朋友，邀他一起学习。我们下节课见。
<div><strong>精选留言（6）</strong></div><ul>
<li><span>Aaron</span> 👍（0） 💬（1）<p>直接go get 好像会更方便啊</p>2021-11-22</li><br/><li><span>taoist</span> 👍（0） 💬（0）<p>这里生成的新项目需要先 go mod tidy 更新依赖</p>2024-01-23</li><br/><li><span>徐石头</span> 👍（0） 💬（0）<p>默认最小版本号是0.1.0吧，不是0.0.1</p>2022-11-11</li><br/><li><span>无笔秀才</span> 👍（0） 💬（0）<p>那么正确的使用方法是 先git clone hade框架，
再进行 hade new?
那么新项目的目录 在hade 框架下？</p>2022-01-17</li><br/><li><span>牛玉富</span> 👍（0） 💬（0）<p>咦，go install不就能一步安装的吗？</p>2022-01-13</li><br/><li><span>2345</span> 👍（0） 💬（1）<p>这个利用脚手架创建新的项目，还需要先下载hade的示例代码吧，不然哪里有hade new命令呢？</p>2021-11-14</li><br/>
</ul>