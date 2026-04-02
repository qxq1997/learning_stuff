你好，我是轩脉刃。

不知道你有没有听过这种说法，优秀程序员应该有三大美德：懒惰、急躁和傲慢，这句话是Perl语言的发明者Larry Wall说的。其中懒惰这一点指的就是，程序员为了懒惰，不重复做同样的事情，会思考是否能把一切重复性的劳动自动化（don’t repeat yourself）。

而框架开发到这里，我们也需要思考，有哪些重复性劳动可以自动化么？

从第十章到现在我们一直在说，框架核心是服务提供者，在开发具体应用时，一定会有很多需求要创建各种各样的服务，毕竟“一切皆服务”；而每次创建服务的时候，我们都需要至少编写三个文件，服务接口、服务提供者、服务实例。**如果能自动生成三个文件，提供一个“自动化创建服务的工具”，应该能节省不少的操作**。

说到创建工具，我们经常需要为了一个事情而创建一个命令行工具，而每次创建命令行工具，也都需要创建固定的Command.go文件，其中有固定的Command结构，这些代码我们能不能偷个懒，“**自动化创建命令行工具**”呢？

另外之前我们做过几次中间件的迁移，先将源码拷贝复制，再修改对应的Gin路径，这个操作也是颇为繁琐的。那么，我们是否可以写一个“**自动化中间件迁移工具**”，一个命令自动复制和替换呢？

这些命令都是可以实现的，这节课我们就来尝试完成这三项自动化，“自动化创建服务工具”， “自动化创建命令行工具”，以及“自动化中间件迁移工具”。

## 自动化创建服务工具

在创建各种各样的服务时，“自动化创建服务工具”能帮我们节省不少开发时间。我们先思考下这个工具应该如何实现。

既然之前已经引入cobra，将框架修改为可以支持命令行工具，创建命令并不是一个难事，我们来定义一套创建服务的provider 命令即可。照旧先设计好要创建的命令，再一一实现。

### 命令创建

“自动化创建服务工具”如何设计命令层级呢？我们设计一个一级命令和两个二级命令：

- `./hade provider` 一级命令，provider，打印帮助信息；
- `./hade provider new` 二级命令，创建一个服务；
- `./hade provider list` 二级命令，列出容器内的所有服务，列出它们的字符串凭证。

首先将provider的这两个二级命令，都存放在command/provider.go中。而对应的一级命令 providerCommand 是一个打印帮助信息的空实现。

```go
// providerCommand 一级命令
var providerCommand = &cobra.Command{
   Use:   "provider",
   Short: "服务提供相关命令",
   RunE: func(c *cobra.Command, args []string) error {
      if len(args) == 0 {
         c.Help()
      }
      return nil
   },
}
```

预先将两个二级命令挂载到这个一级命令中，在 framework/command/provider.go：

```go
// 初始化provider相关服务
func initProviderCommand() *cobra.Command {
   providerCommand.AddCommand(providerCreateCommand)
   providerCommand.AddCommand(providerListCommand)
   return providerCommand
}
```

并且在 framework/command/kernel.go，将这个一级命令挂载到一级命令rootCommand中：

```go
func AddKernelCommands(root *cobra.Command) {
   // provider一级命令
   root.AddCommand(initProviderCommand()
}
```

下面来实现这两个二级命令new和list。

### List命令的实现

先说 `./hade provider list` 这个命令，因为列出容器内的所有服务是比较简单的。还记得吗，在十一章实现服务容器的时候，其中有一个providers，它存储所有的服务容器提供者，放在文件 framework/container.go 中：

```go
// HadeContainer 是服务容器的具体实现
type HadeContainer struct {
	...
	// providers 存储注册的服务提供者，key 为字符串凭证
	providers map[string]ServiceProvider
    ...
}
```

我们只需要将这个providers进行遍历，根据其中每个ServiceProvider的Name() 方法，获取字符串凭证列表即可。

所以，在framework/container.go 的HadeContainer中，增加一个NameList方法，返回所有提供服务者的字符串凭证，方法也很简单，直接遍历这个providers 字段。

```go
// NameList 列出容器中所有服务提供者的字符串凭证
func (hade *HadeContainer) NameList() []string {
   ret := []string{}
   for _, provider := range hade.providers {
      name := provider.Name()
      ret = append(ret, name)
   }
   return ret
}
```

而在 framework/command/provider.go 中的providerListCommand 命令中，我们调用这个命令并且打印出来。

```go
// providerListCommand 列出容器内的所有服务
var providerListCommand = &cobra.Command{
   Use:   "list",
   Short: "列出容器内的所有服务",
   RunE: func(c *cobra.Command, args []string) error {
      container := c.GetContainer()
      hadeContainer := container.(*framework.HadeContainer)
      // 获取字符串凭证
      list := hadeContainer.NameList()
      // 打印
      for _, line := range list {
         println(line)
      }
      return nil
   },
}
```

可以验证一下。编译 `./hade build self` 并且执行 `./hade provider list` ，可以看到如下信息：  
![](https://static001.geekbang.org/resource/image/0c/35/0c4d1fb73cd17aabc02fe7c3b5f2f335.png?wh=481x215)

你可以很清晰看到容器中绑定了哪些服务提供者，它们的字符串凭证是什么。这样我们在定义一个新的服务的时候，可以很方便看到哪些服务提供者的关键字已经被使用了，避免使用已有的服务关键字。

下面我们来说稍微复杂一点的创建服务的命令 `./hade provider new` 。

### new命令的实现

在实际业务开发过程中，我们一想到一个服务，比如去某个用户系统获取信息，一定会想到创建服务的三步骤：创建一个用户系统的交互协议contract.go、再创建一个提供协议的用户服务提供者 provider.go、最后才实现具体的用户服务实例 service.go。

每次都需要创建这三个文件，且这三个文件的文件大框架都有套路可言。那我们如何将这些重复的套路性的代码自动化生成呢？

首先这里有一个增加参数的过程，我们需要知道要创建服务的服务名是什么？创建这个服务的文件夹名字是什么？当然了，这些参数也可以使用在命令后面增加flag参数的方式来表示。但是其实还有一种更便捷的方式：交互。

交互的表现形式如：

```go
输入：./hade provider new (我想创建一个服务)
输出：请输入服务名称(服务凭证):
输入：demo
输出：请求输入服务目录名称(默认和服务名称相同)：
输入：demo
输出：创建服务成功, 文件夹地址：xxxxx
输出：请不要忘记挂载新创建的服务
```

这种命令行交互的方式是不是更智能化？但是如何实现呢？

这里我们借助一个第三方库 [survey](https://github.com/AlecAivazis/survey)。这个库目前在GitHub上已经有2.7k个star，最新版本是v2版本，使用的是MIT License协议，可以放心使用。这个survey库支持多种交互模式：单行输入、多行输入、单选、多选、y/n 确认选择，在[项目GitHub首页](https://github.com/AlecAivazis/survey)上就能很清晰看到这个库的使用方式。

```go
name := false
// 使用survey.XXX 的方式来选择交互形式
prompt := &survey.Confirm{
    Message: "Do you like pie?",
}
// 使用&将最终的选择存储进入变量
survey.AskOne(prompt, &name)
```

在provider new命令中，我们也可以用survey 来增加交互性。通过交互，我们可以确认用户想创建的服务凭证，以及想把这个服务创建在 app/provider/ 下的哪个目录中。

当然，**在用户通过交互输入了服务凭证和服务目录之后，是需要进行参数判断的**。服务凭证需要和容器中已注册服务的字符串凭证进行比较，如果已经存在了，应该报错；而服务目录如果已经存在，也应该直接报错。

如果都验证ok了，最后一步就是在 app/provider/ 下创建对应的服务目录，在目录下创建contract.go、provider.go、service.go 三个文件，并且在三个文件中根据预先定义好的模版填充内容。这里我们如何实现呢？使用模版、变更模版中的某些字段、形成新的文本，这个你应该能联想到 Golang 标准库中的 [text/template](https://pkg.go.dev/text/template) 库。

这个库的使用方法比较多，我这里把我们用得到的方法解说一下，解析contract.go文件的生成过程，就可以了解其使用方法了。

```go
// 创建title这个模版方法
funcs := template.FuncMap{"title": strings.Title}
{
   //  创建contract.go
   file := filepath.Join(pFolder, folder, "contract.go")
   f, err := os.Create(file)
   if err != nil {
      return errors.Cause(err)
   }
   // 使用contractTmp模版来初始化template，并且让这个模版支持title方法，即支持{{.|title}}
   t := template.Must(template.New("contract").Funcs(funcs).Parse(contractTmp))
   // 将name传递进入到template中渲染，并且输出到contract.go 中
   if err := t.Execute(f, name); err != nil {
      return errors.Cause(err)
   }
}
```

上面代码的逻辑最核心的就是创建模版的template.Must 和渲染模版的t.Execute方法。

但是在创建模版之前，我们使用了一个**template.FuncMap方法，它比较不好理解，主要作用就是在模版中，让我们可以使用定义的模版方法来控制渲染效果**。这个FuncMap结构定义了模版中支持的模版方法，比如我支持title这个方法，这个方法实际调用的是string.Title 函数，把字符串首字母大写。

在刚才的代码中，我们使用contractTmp来创建模版，在渲染contractTmp的时候，传递了一个name变量。假设这个name变量代表的是字符串user，而我希望创建一个字符串“NameKey”的变量，可以这么定义contractTmp：

```go
var contractTmp string = `package {{.}}

const {{.|title}}Key = "{{.}}"

type Service interface {
   // 请在这里定义你的方法
    Foo() string
}
`
```

注意到了么，其中的{{.|title}} 实际上是相当于调用了strings.Title(name) 的方法填充，能将字符串name替换为字符串Name。

而定义好了FuncMap之后，我们随后使用了os.Create创建contract.go文件，然后初始化template：

```plain
t := template.Must(template.New("contract").Funcs(funcs).Parse(contractTmp))
```

这行代码的几个函数我们来看看。

**template.Must 表示后面的template创建必须成功，否则会panic**。这种Must的方法来简化代码的error处理逻辑，在标准库中经常使用。我们的hade框架的MustMake也是同样的原理。

template.New() 方法，创建一个text/template 的 Template结构，其中的参数contract字符串是为这个Template结构命名的，后面的Funcs() 方法是将签名定义的模版函数注册到这个Template结构中，最后的Parse()是使用这个Template结构解析具体的模版文本。

定义好了模版t之后，使用代码：

```go
t.Execute(f, name)
```

来将变量name 注册进入模版t，并且输出到f。这里的f，是我们之前创建的contract.go文件。也就是使用变量name解析模版t，输出到contract.go文件中。

这里的变量可以是一个struct结构，也可以是基础变量，比如我们这里定义的字符串。在模版中{{.}} 就代表这个结构。所以再回顾前面定义的contractTmp模版，你会看出其中变量name为字符串user的时候，最终的显示是什么吗？

好，创建服务命令的所有思路我们就梳理清楚了，最后也贴出完整的代码供你参考，关键步骤都在注释中详细说明了，实现并不难：

```go
// providerCreateCommand 创建一个新的服务，包括服务提供者，服务接口协议，服务实例
var providerCreateCommand = &cobra.Command{
   Use:     "new",
   Aliases: []string{"create", "init"},
   Short:   "创建一个服务",
   RunE: func(c *cobra.Command, args []string) error {
      container := c.GetContainer()
      fmt.Println("创建一个服务")
      var name string
      var folder string
      {
         prompt := &survey.Input{
            Message: "请输入服务名称(服务凭证)：",
         }
         err := survey.AskOne(prompt, &name)
         if err != nil {
            return err
         }
      }
      {
         prompt := &survey.Input{
            Message: "请输入服务所在目录名称(默认: 同服务名称):",
         }
         err := survey.AskOne(prompt, &folder)
         if err != nil {
            return err
         }
      }
      // 检查服务是否存在
      providers := container.(*framework.HadeContainer).NameList()
      providerColl := collection.NewStrCollection(providers)
      if providerColl.Contains(name) {
         fmt.Println("服务名称已经存在")
         return nil
      }
      if folder == "" {
         folder = name
      }
      app := container.MustMake(contract.AppKey).(contract.App)
      pFolder := app.ProviderFolder()
      subFolders, err := util.SubDir(pFolder)
      if err != nil {
         return err
      }
      subColl := collection.NewStrCollection(subFolders)
      if subColl.Contains(folder) {
         fmt.Println("目录名称已经存在")
         return nil
      }
      // 开始创建文件
      if err := os.Mkdir(filepath.Join(pFolder, folder), 0700); err != nil {
         return err
      }
      // 创建title这个模版方法
      funcs := template.FuncMap{"title": strings.Title}
      {
         //  创建contract.go
         file := filepath.Join(pFolder, folder, "contract.go")
         f, err := os.Create(file)
         if err != nil {
            return errors.Cause(err)
         }
         // 使用contractTmp模版来初始化template，并且让这个模版支持title方法，即支持{{.|title}}
         t := template.Must(template.New("contract").Funcs(funcs).Parse(contractTmp))
         // 将name传递进入到template中渲染，并且输出到contract.go 中
         if err := t.Execute(f, name); err != nil {
            return errors.Cause(err)
         }
      }
      {
         // 创建provider.go
         file := filepath.Join(pFolder, folder, "provider.go")
         f, err := os.Create(file)
         if err != nil {
            return err
         }
         t := template.Must(template.New("provider").Funcs(funcs).Parse(providerTmp))
         if err := t.Execute(f, name); err != nil {
            return err
         }
      }
      {
         //  创建service.go
         file := filepath.Join(pFolder, folder, "service.go")
         f, err := os.Create(file)
         if err != nil {
            return err
         }
         t := template.Must(template.New("service").Funcs(funcs).Parse(serviceTmp))
         if err := t.Execute(f, name); err != nil {
            return err
         }
      }
      fmt.Println("创建服务成功, 文件夹地址:", filepath.Join(pFolder, folder))
      fmt.Println("请不要忘记挂载新创建的服务")
      return nil
   },
}
var contractTmp string = `package {{.}}
const {{.|title}}Key = "{{.}}"
type Service interface {
   // 请在这里定义你的方法
    Foo() string
}
`
var providerTmp string = `package {{.}}
import (
   "github.com/gohade/hade/framework"
)
type {{.|title}}Provider struct {
   framework.ServiceProvider
   c framework.Container
}
func (sp *{{.|title}}Provider) Name() string {
   return {{.|title}}Key
}
func (sp *{{.|title}}Provider) Register(c framework.Container) framework.NewInstance {
   return New{{.|title}}Service
}
func (sp *{{.|title}}Provider) IsDefer() bool {
   return false
}
func (sp *{{.|title}}Provider) Params(c framework.Container) []interface{} {
   return []interface{}{c}
}
func (sp *{{.|title}}Provider) Boot(c framework.Container) error {
   return nil
}
`
var serviceTmp string = `package {{.}}
import "github.com/gohade/hade/framework"
type {{.|title}}Service struct {
   container framework.Container
}
func New{{.|title}}Service(params ...interface{}) (interface{}, error) {
   container := params[0].(framework.Container)
   return &{{.|title}}Service{container: container}, nil
}
func (s *{{.|title}}Service) Foo() string {
    return ""
}
`

```

最后我们验证一下这个创建服务命令。同样编译./hade 命令之后，执行 `./hade provider new` , 定义服务凭证为user，目录名称同样为user。  
![](https://static001.geekbang.org/resource/image/b7/3c/b7ae3ba7edee1ce7a216e891d1b8e23c.png?wh=620x193)

能看到 app/provider/ 目录下创建了user文件夹，其中有contract.go、provider.go、service.go三个文件：  
![](https://static001.geekbang.org/resource/image/46/e6/46900bb2ea53135b890763687f4cc0e6.png?wh=376x276)

其中每个文件的定义都完整，且可以直接再次编译通过，验证完成！

## 自动化创建命令行工具

到这里我们就完成了创建服务工具的自动化。开头提到具体运营一个应用的时候，我们也会经常需要创建一个自定义的命令行。比如运营一个网站，可能会创建一个命令来统计网站注册人数，也可能要创建一个命令来定期检查是否有违禁的文章需要封禁等。所以自动创建命令行工具在实际工作中是非常有必要的。

同服务命令一样，我们可以有一套创建命令行工具的命令。

- `./hade command` 一级命令，显示帮助信息
- `./hade command list` 二级命令，列出所有控制台命令
- `./hade command new` 二级命令，创建一个控制台命令

command相关的命令和provider的命令的实现基本是一致的。这里我们简要解说下重点，具体对应的代码详情可以参考GitHub上的[framework/command/cmd.go](https://github.com/gohade/coredemo/blob/geekbang/21/framework/command/cmd.go) 文件。

一级命令./hade command 我们就不说了，是简单地显示帮助信息。

二级命令 ./hade command list。功能是列出所有的控制台命令。这个功能实际上和直接调用 ./hade 显示的帮助信息差不多，把一级根命令全部列了出来，只不过我们使用了一个更为语义化的 ./hade command list 来显示。  
![](https://static001.geekbang.org/resource/image/85/9e/85fd992ca12552e3d5fef51994b1079e.png?wh=946x722)

它的实现也并不复杂，具体就是使用Root().Commands() 方法遍历一级跟命令的所有一级命令。

```go
// cmdListCommand 列出所有的控制台命令
var cmdListCommand = &cobra.Command{
   Use:   "list",
   Short: "列出所有控制台命令",
   RunE: func(c *cobra.Command, args []string) error {
      cmds := c.Root().Commands()
      ps := [][]string{}
      for _, cmd := range cmds {
         line := []string{cmd.Name(), cmd.Short}
         ps = append(ps, line)
      }
      util.PrettyPrint(ps)
      return nil
   },
}
```

二级命令 ./hade command new创建命令行工具，就是在app/console/command/ 文件夹下增加一个目录，然后在这个目录中存放命令的相关代码。

比如要创建一个foo命令，就是要在app/console/command/ 目录下创建一个foo目录，其中创建一个foo.go 文件名，这个文件名可以随意起，这里我们就和目录名保持一致。然后在 app/console/command/foo.go 文件中输入模版：

```go
// 命令行工具模版
var cmdTmpl string = `package {{.}}

import (
   "fmt"

   "github.com/gohade/hade/framework/cobra"
)

var {{.|title}}Command = &cobra.Command{
   Use:   "{{.}}",
   Short: "{{.}}",
   RunE: func(c *cobra.Command, args []string) error {
        container := c.GetContainer()
      fmt.Println(container)
      return nil
   },
}
```

实现步骤也很简单：survery 交互先要求用户输入命令名称；然后要求用户输入文件夹名称，记得检查命令名称和文件夹名称是否合理；之后创建文件夹 app/console/command/xxx 和文件 app/console/command/xxx/xxx.go；最后使用template将模版写入文件中。

## 自动化中间件迁移工具

除了服务工具和命令行工具的创建，对于中间件，我们在开发过程中也是经常会使用创建的，同样的，可以为中间件定义一系列的命令来自动化。

- `./hade middleware` 一级命令，显示帮助信息
- `./hade middleware list` 二级命令，列出所有的业务中间件
- `./hade middleware new` 二级命令，创建一个新的业务中间件
- `./hade middleware migrate` 二级命令，迁移Gin已有的中间件

其中的前面三个命令基本上和provider、command 命令如出一辙，我们就不赘述了，同样你可以通过GitHub 上的[framework/command/middleware.go 文件](https://github.com/gohade/coredemo/blob/geekbang/21/framework/command/middleware.go)参考其具体实现，相信你可以顺利写出来。

这里重点说一下 `./hade middleware migrate` 命令。

不知道你有没有好奇，为什么迁移也要写一个命令？当时在将Gin迁移进入hade框架的时候我们说，Gin作为一个成熟的开源作品，有丰富的中间件库，存放GitHub的一个项目 [gin-contrib](https://github.com/gin-contrib/) 中。那么在开发过程中，我们一定会经常需要使用到这些中间件。

但是由于这些中间件使用到的Gin框架的地址为 ：

```plain
github.com/gin-gonic/gin
```

而我们的Gin框架地址为：

```plain
github.com/gohade/hade/framework/gin
```

所以我们不能使用import直接使用这些中间件，那么有没有一个办法，能直接一键迁移gin-contrib下的某个中间件呢？比如 `git@github.com:gin-contrib/cors.git` ，直接拷贝并且自动修改好Gin框架引用地址，放到我们的 app/http/middleware/ 目录中。

于是就有了这个 `./hade middleware migragte` 命令。下面就梳理一下这个命令的逻辑步骤。以下载cors中间件为例，我们的思路是从GitHub上将这个[cors项目](https://github.com/gin-contrib/cors)复制下来，**并且删除这个项目的一些不必要的文件**。

什么是不必要的文件呢？.git目录、go.mod、go.sum，这些都是作为一个“项目”才会需要的，而我们要把项目中的这些删掉，让它成为一个文件，存放在我们的app/http/middleware/cors目录下。最后再遍历这个目录的所有文件，将所有出现“github.com/gin-gonic/gin” 的地方替换为“github.com/gohade/hade/framework/gin”就可以了。

从git上复制一个项目，在Golang中可以使用一个第三方库 [go-git](https://github.com/go-git/go-git)，这个第三方库已经有2.7k 个star，且基于Apache 的Licence，是可以直接import使用的。目前这个库最新的版本为v5。

它的使用方式如下：

```go
_, err := git.PlainClone("/tmp/foo", false, &git.CloneOptions{
    URL:      "https://github.com/go-git/go-git",
    Progress: os.Stdout,
})
```

将某个Git的URL地址使用gitclone，下载到/tmp/foo目录，并且把输出也输出到控制台。

我们也可以使用这样的方式进行复制。具体的代码逻辑也不难，归纳一下，migrate的实现步骤如下：

1. 参数中获取中间件名称；
2. 使用go-git，将对应的gin-contrib的项目clone到目录/app/http/middleware；
3. 删除不必要的文件go.mod、go.sum、.git；
4. 替换关键字 “github.com/gin-gonic/gin”。

在framework/command/middleware.go中，对应的代码如下：

```go
// 从gin-contrib中迁移中间件
var middlewareMigrateCommand = &cobra.Command{
   Use:   "migrate",
   Short: "迁移gin-contrib中间件, 迁移地址：https://github.com/gin-contrib/[middleware].git",
   RunE: func(c *cobra.Command, args []string) error {
      container := c.GetContainer()
      fmt.Println("迁移一个Gin中间件")
      // step1: 获取参数
      var repo string
      {
         prompt := &survey.Input{
            Message: "请输入中间件名称：",
         }
         err := survey.AskOne(prompt, &repo)
         if err != nil {
            return err
         }
      }
      // step2 : 下载git到一个目录中
      appService := container.MustMake(contract.AppKey).(contract.App)

      middlewarePath := appService.MiddlewareFolder()
      url := "https://github.com/gin-contrib/" + repo + ".git"
      fmt.Println("下载中间件 gin-contrib:")
      fmt.Println(url)
      _, err := git.PlainClone(path.Join(middlewarePath, repo), false, &git.CloneOptions{
         URL:      url,
         Progress: os.Stdout,
      })
      if err != nil {
         return err
      }

      // step3:删除不必要的文件 go.mod, go.sum, .git
      repoFolder := path.Join(middlewarePath, repo)
      fmt.Println("remove " + path.Join(repoFolder, "go.mod"))
      os.Remove(path.Join(repoFolder, "go.mod"))
      fmt.Println("remove " + path.Join(repoFolder, "go.sum"))
      os.Remove(path.Join(repoFolder, "go.sum"))
      fmt.Println("remove " + path.Join(repoFolder, ".git"))
      os.RemoveAll(path.Join(repoFolder, ".git"))

      // step4 : 替换关键词
      filepath.Walk(repoFolder, func(path string, info os.FileInfo, err error) error {
         if info.IsDir() {
            return nil
         }

         if filepath.Ext(path) != ".go" {
            return nil
         }

         c, err := ioutil.ReadFile(path)
         if err != nil {
            return err
         }
         isContain := bytes.Contains(c, []byte("github.com/gin-gonic/gin"))
         if isContain {
            fmt.Println("更新文件:" + path)
            c = bytes.ReplaceAll(c, []byte("github.com/gin-gonic/gin"), []byte("github.com/gohade/hade/framework/gin"))
            err = ioutil.WriteFile(path, c, 0644)
            if err != nil {
               return err
            }
         }

         return nil
      })
      return nil
   },
}
```

我们可以下载cors项目做一下验证，运行 `./hade middleware migrate` 命令，并且输入cors。你会在控制台看到这些信息：  
![](https://static001.geekbang.org/resource/image/6f/5f/6fd8197207c92b3b362a89cc4676015f.png?wh=682x384)

并且在目录中看到cors中间件已经完整下载下来了。  
![](https://static001.geekbang.org/resource/image/70/09/709dbbc8c2140byy56459c202aa66909.png?wh=343x610)

然后，可以直接在app/http/route.go中直接使用这个cors中间件：

```go
...

// Routes 绑定业务层路由
func Routes(r *gin.Engine) {
   ...
   // 使用cors中间件
   r.Use(cors.Default())
   ...
 }
```

验证完成！

今天所有代码都保存在GitHub上的[geekbang/21](https://github.com/gohade/coredemo/tree/geekbang/21)分支了。附上目录结构供你对比查看，只修改了framework/command/目录下的cmd.go、provider.go、middleware.go文件。  
![](https://static001.geekbang.org/resource/image/78/89/7889877151dc4d4e306554a64c550c89.png?wh=476x936)

## 小结

今天增加的命令不少，自动化创建服务工具、命令行工具，以及中间件迁移工具，这些命令都为我们后续开发应用提供了不少便利。

其实每个自动化命令行工具实现的思路都是差不多的，先思考清楚对于这个工具我们要自动化生成什么，然后使用代码和对应的模版生成对应的文件，并且替换其中特有的单词。原理不复杂，但是对于实际的工作，是非常有帮助的。

这一节课你应该可以感受到之前将cobra引入我们的框架是一个多么正确的决定，在cobra之上，我们才能实现这些方便的自动化工具。

### 思考题

我们实现的自动化服务./hade command list命令，目前只展示了一级命令，在写这篇文章的时候我反思了一下，其实可以扩展成为树形结构展示，同时展示一级/二级/三级/命令。你可以想想如何实现，如果可以的话，可以去github.com/gohade/hade 项目中提交一个merge request 来补充这个功能吧！

欢迎在留言区分享你的思考。我们下节课见。
<div><strong>精选留言（4）</strong></div><ul>
<li><span>zzq</span> 👍（0） 💬（1）<p>大佬， 在 framework&#47;command&#47;middleware.go 文件中缺少了    默认: 同中间件名称。 if folder == &quot;&quot; {folder = name}   </p>2021-12-01</li><br/><li><span>kkxue</span> 👍（3） 💬（0）<p>课程设计的好棒</p>2021-11-05</li><br/><li><span>qinsi</span> 👍（1） 💬（1）<p>中间件也要拷贝代码吗...是否可以安装以后在go.mod里replace呢？</p>2021-11-05</li><br/><li><span>taoist</span> 👍（0） 💬（0）<p>go-git 配置http代理：
		res_url := &quot;https:&#47;&#47;github.com&#47;gin-contrib&#47;&quot; + repo + &quot;.git&quot;
		fmt.Println(&quot;下载中间件 gin-contrib:&quot;, res_url)
	
		&#47;&#47;自定义 http proxy
		proxy_url, _ := url.Parse(&quot;http:&#47;&#47;127.0.0.1:7890&quot;)
		customHttp := &amp;http.Client{
			Transport: &amp;http.Transport{
				Proxy: http.ProxyURL(proxy_url),
			},
		}
		client.InstallProtocol(&quot;https&quot;, githttp.NewClient(customHttp))
		_, err := git.PlainClone(path.Join(middlewarePath, repo), false, &amp;git.CloneOptions{
			URL:      res_url,
			Progress: os.Stdout,
		})</p>2024-01-20</li><br/>
</ul>